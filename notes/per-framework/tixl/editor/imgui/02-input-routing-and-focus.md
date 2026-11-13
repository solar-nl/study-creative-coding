# Chapter 02: Input Routing and Focus - Who Gets the Keystroke?

> *Pressing Delete should delete a node, unless you are typing in a text box, in which case it should delete a letter.*

---

## The Problem: Shortcuts That Fire While You Type

Picture a multi-window editor: a node canvas, an inspector, a parameter popup, a timeline. You select a node, click into an inspector text field, and type "Delete me later". Without protection, the `D` duplicates the node, the `e` triggers a shortcut, the `Delete`/`Backspace` removes the selected node, and `Tab` opens a node browser. The text field receives nothing useful. Every canvas shortcut sees the same global keyboard state as the text field, because ImGui has one keyboard and many windows.

The mouse has the mirror-image problem. A canvas wants to pan on a drag, select on a click, and let nodes be dragged. A color picker overlay floating above it wants the same drag. A scrub handle wants it too. If all of them react to the same press, you drag a slider and the whole canvas pans.

This chapter traces how tixl answers both problems. Its answer is surprisingly small: one guard function, a handful of per-action flags, and one per-frame boolean. The scoping is implicit rather than declared. That has real consequences, and we will point out where it helps and where it bites. At the end we translate the pattern for a Rust editor built on dear-imgui-rs.

**Mental model: a building with one intercom.** ImGui broadcasts keyboard state on a single intercom to every room. A shortcut is a person who stands up when they hear their key. The guard is a door rule: "only react if you are in the room that has the floor (focus or hover), and nobody in the building is mid-sentence (an item is active)." There is no receptionist assigning rooms. Each room simply checks the rule when it polls.

> **Scope note.** All paths in this chapter are relative to `visual-programming/tixl/`, and are cited as `Editor/...:line`. Related reading, not restated here: [keyboard interaction in MagGraph](../maggraph/13-interaction-keyboard.md), [the graph state machine](../maggraph/07-state-machine.md), [the symbol browser](../maggraph/11-interaction-browser.md), and [ImGui patterns](../maggraph/B-imgui-patterns.md).

---

## How Does a Shortcut Get Declared, Bound, and Polled?

The model has three layers, and keeping them separate is what makes rebinding possible.

1. **Declare.** `UserActions` is a flat enum (`Editor/Gui/Interaction/UserAction.cs:9`). Its order is the order shown in the shortcut editor. A trailing `__Count` sentinel sizes per-action arrays (`Editor/Gui/Interaction/Keyboard/KeyActionHandling.cs:184-185`).
2. **Bind.** A `KeyBinding` pairs an action with a `KeyCombination` (`Editor/Gui/Interaction/Keyboard/KeyBinding.cs:14-24`). `KeyCombination` is a small struct of key plus ctrl, alt, shift (`KeyCombination.cs:9-14`). Modifiers match exactly, so a Ctrl+D binding does not fire on Ctrl+Shift+D (`KeyCombination.cs:16-21`). Defaults live in `FactoryKeyMap.cs`, for example `new(UserActions.Duplicate, new KeyCombination(Key.D, ctrl: true))` (`FactoryKeyMap.cs:14`). One action can own several keys: Delete and Backspace both map to delete (`FactoryKeyMap.cs:16-17`).
3. **Poll.** Call sites ask a question each frame. There is no event subscription and no callback registry. The Duplicate handler is literally `if (UserActions.Duplicate.Triggered())` (`Editor/Gui/MagGraph/Interaction/KeyboardActions.cs:28`).

Notice what is missing from the keymap: context. The keymap says "Ctrl+D means Duplicate". It does not say "in the graph window only". That information lives elsewhere, in per-action behaviour flags.

### The Per-Action Flags

Each action registers behaviour flags in `KeyActionHandling.InitializeActionOptions` (`KeyActionHandling.cs:106-167`). The flags are declared at `KeyActionHandling.cs:92-101`:

| Flag | Meaning |
|------|---------|
| `NeedsWindowFocus` | The current window (or a child) must be focused |
| `NeedsWindowHover` | The mouse must be over the current window (or a child) |
| `RemainActiveWhenItemActive` | Opt out of the "no shortcuts while an input is active" rule |
| `KeyPressOnly` | Fire on the press edge, no key repeat |
| `KeyHoldOnly` | Fire while the key is held |

A static table holds these flags and each binding copies its flags at construction (`KeyBinding.cs:18`). Because the flags are not part of the keymap file, users can rebind keys but cannot rebind context.

### What Triggered() Does Each Frame

`UserActions.X.Triggered()` is an extension method (`KeyActionHandling.cs:40-61`). Here is the sequence, in order:

1. `InitializeFrame()` runs once per frame (`KeyActionHandling.cs:18-38`, called from `Editor/Program.cs:214`) and records whether any key is down.
2. If no key is down this frame, `Triggered()` returns false immediately.
3. If `UserSettings.Config.EnableKeyboardShortCuts` is off, it returns false (`KeyActionHandling.cs:42`).
4. Otherwise it walks the current keymap's bindings and returns true on the first binding whose action matches, whose `IsContextValid()` passes, and whose `IsTriggered(io)` passes (`KeyActionHandling.cs:48-58`).

`IsTriggered` picks the ImGui query by flag: `IsKeyPressed(key, repeat: true)` by default, `repeat: false` for `KeyPressOnly`, and `IsKeyDown` for `KeyHoldOnly` (`KeyBinding.cs:44-57`).

The early-out on "no key down" is a nice detail. The common case costs one boolean check per poll, so you can sprinkle `Triggered()` calls through draw code without worrying.

---

## The Central Guard: What Does IsContextValid() Check?

Every shortcut passes through one function, `KeyBinding.IsContextValid()` (`KeyBinding.cs:26-42`). Here is the verbatim core. Read it as the three door rules from the intercom analogy, checked top to bottom:

```
if ((_flags & NeedsWindowFocus) != 0 && !ImGui.IsWindowFocused(ImGuiFocusedFlags.ChildWindows)) return false;
if ((_flags & NeedsWindowHover) != 0 && !ImGui.IsWindowHovered(ImGuiHoveredFlags.ChildWindows)) return false;
// Prevent keyboard shortcuts while inputs are active
if ((_flags & RemainActiveWhenItemActive) == 0 && ImGui.IsAnyItemActive()) return false;
return true;
```

The semantics worth internalizing:

- **Check order is cheap-to-expensive and opt-in-to-default.** Focus and hover are opt-in per action. The active-item rule is opt-out: it applies to every action unless `RemainActiveWhenItemActive` is set. The code comments at `KeyBinding.cs:36` and `KeyActionHandling.cs:98` both document this "block shortcuts while any input is active" default.
- **Only the WASD camera actions opt out** (`KeyActionHandling.cs:157-162`). The camera keys are the one case where the code deliberately lets a shortcut coexist with an active item.
- **An action with no flags is blocked only by `IsAnyItemActive()`.** It is not blocked by window focus. If you forget to set `NeedsWindowFocus`, the shortcut fires from any window that polls it while nothing is being edited.
- **`IsAnyItemActive()` is the text-field protection.** A focused `InputText` is the active item, so every default shortcut dies for as long as you are typing. That single line is what makes the opening scenario work.

### Wait, Which Window Is "Current"?

This is the part that surprises people. There is no window registry. `IsWindowFocused` and `IsWindowHovered` apply to whatever window is current when `Triggered()` runs, so the caller's `Begin`/`End` scope is the context: the room you are standing in when you ask. Poll from inside the graph window and "focus" means the graph window. Poll from a different window's draw code and the same action means something else.

The guard also does not consult `WantTextInput` or `WantCaptureKeyboard` centrally. `WantTextInput` appears only in a few local sites: `Editor/Gui/Windows/OutputSetup/SetupOutputView.ScaleLine.cs:111`, `SetupOutputView.PlanDraw.cs:109`, `SetupOutputView.Board.cs:1643`, and `Editor/Gui/Windows/SnapshotControlView.cs:222`. The pattern there is `IsWindowFocused(RootAndChildWindows) && !WantTextInput`. `WantCaptureKeyboard` is never used.

---

## Where Does Context Scoping Come From If Nothing Declares It?

It is implicit and has three ingredients: who polls, which flags the action carries, and extra local guards. There is no context enum and there are no per-context keymaps.

Here is the deliberate same-key-two-contexts case. `C` maps to `InsertKeyframe` (`FactoryKeyMap.cs:38`) with `NeedsWindowFocus | KeyPressOnly` (`KeyActionHandling.cs:130`). `C` also maps to `CameraFocusSelection` (`FactoryKeyMap.cs:85`) with `NeedsWindowHover` (`KeyActionHandling.cs:166`). Both bindings exist in one keymap. Which one fires depends on who polls and which flag passes. There is no priority system. Within one window, the first matching binding wins.

### Extra Local Guards Layered On Top

Some call sites add their own conditions on top of `IsContextValid()`:

- Tab to create a placeholder requires `View.IsFocused && View.IsHovered && !IsAnyItemActive()` (`Editor/Gui/MagGraph/States/GraphStates.cs:48-50`). `IsFocused` is `IsWindowFocused(RootAndChildWindows)` and `IsHovered` is `IsWindowHovered()` (`Editor/Gui/MagGraph/Ui/MagGraphCanvas.Drawing.cs:26-27`).
- Copy and paste re-check `!IsAnyItemActive()` (`KeyboardActions.cs:123-140`). The comment reads "Prevent node graph copy if a text input is active (e.g., section description)".
- Duplicate has a guard because duplicating with an empty clipboard would paste stale content (`KeyboardActions.cs:30-31`).
- The legacy symbol browser opens on Tab release only if it has focus and nothing is active (`Editor/Gui/Graph/Legacy/Interaction/SymbolBrowser.cs:83-87`):

```
var hasFocus = ImGui.IsWindowFocused(ImGuiFocusedFlags.ChildWindows);
var anythingActive = ImGui.IsAnyItemActive();
if (!hasFocus || anythingActive || !ImGui.IsKeyReleased(Key.Tab.ToImGuiKey())) return;
```

- The legacy graph view requires `IsWindowFocused() && !editingSomething` for camera keys, where `editingSomething` is `IsAnyItemActive()` (`Editor/Gui/Graph/Legacy/GraphView.cs:312-317`).

### Stated Rule vs. Code

| Stated rule | What the code does |
|-------------|--------------------|
| "Shortcuts are blocked while any input is active" (`KeyBinding.cs:36`, `KeyActionHandling.cs:98`) | True for actions routed through `Triggered()`. Direct `IsKeyPressed` checks (Enter, Escape in rename and placeholder UIs) bypass the guard entirely. |
| "Context is a property of the shortcut" | Context is a property of the call site. Flags give coarse focus/hover behaviour, but the caller's `Begin` scope decides what "focused" means. |
| "A key combo maps to one action" | The keymap editor enforces this with a global check, while the factory map deliberately shares `C` across two contexts (see Gotchas). |
| "Keyboard input is protected from shortcuts" | Mostly by `IsAnyItemActive()`, not by `WantTextInput`. Only four sites use `WantTextInput`. |

### Rebinding and the Global Conflict Check

The shortcut editor captures a key through `KeyHandler.GetPressedKey()` plus modifier toggles (`Editor/Gui/Interaction/Keyboard/KeyMapEditor.cs:190-226`). It warns "Already used for X" via `TryGetConflictingBinding` (`KeyMapEditor.cs:230-234`, `KeyMap.cs:54-70`). On Assign, `AddBinding` removes the action's existing binding first, so each action keeps one key, then removes the conflicting action's binding (`KeyMap.cs:105-108`, `KeyMapEditor.cs:244-249`). Keymaps persist as JSON (`KeyMapSwitching.cs:39-51`), and `CurrentKeymap` is static (`KeyMapSwitching.cs:15`). The conflict check compares only the key combination, never the context.

---

## How Do Canvases Arbitrate the Mouse?

Keyboard state is global, but the mouse has a position, so ImGui gives you more to work with. tixl uses three tools: item ordering, a one-frame "overlay captured the mouse" flag, and explicit drag ownership.

### Tool 1: InvisibleButton Ordering

Every node emits an `InvisibleButton("##op")` over its rectangle (`Editor/Gui/MagGraph/Ui/MagGraphCanvas.DrawNode.cs:181-190`). Hover is read with `IsItemHovered(AllowWhenBlockedByPopup | AllowWhenBlockedByActiveItem)`. A node becomes `_context.ActiveItem` only in the Default state and only if its custom operator UI is not itself active (`DrawNode.cs:192-196`).

Think of the nodes as transparent stickers laid on the canvas. When two stickers overlap, the one placed last is on top. The project's rule is "last InvisibleButton wins": emit the topmost thing last, or split interaction into separate channels (`.agentic/AGENT_INSTRUCTIONS.md:216`).

### Tool 2: The Canvas Arbitration Block

`Editor/Gui/Interaction/ScalableCanvas.cs:236-275` decides whether the canvas may react:

- `isDirectlyHovered` is `IsWindowHovered(ChildWindows | AllowWhenBlockedByPopup | AllowWhenBlockedByActiveItem)`.
- `isInteractable = isDirectlyHovered && !FrameStats.Last.OpenedPopupHovered`.
- `isAnotherItemActive` reads the frame flag `OpenedPopupCapturedMouse` (`ScalableCanvas.cs:259`). The more obvious `IsAnyItemActive()` is commented out there.
- Panning requires `(isInteractable || isPanning)`. The `|| isPanning` means an already-running pan keeps going when the cursor leaves the window.
- Drag ownership is a static `_draggedCanvas` (`ScalableCanvas.cs:241,251,273`), cleared when the right-drag ends.

### Tool 3: The Overlay-Captured-Mouse Flag

Anything that floats above the canvas and takes a drag sets `FrameStats.Current.OpenedPopupCapturedMouse = true`. Three examples: the playback scrub handler (`Editor/Gui/Interaction/Timing/PlaybackTimeScrubHandling.cs:58`, comment "Avoid pointer conflicts with regular UI while scrub gizmo is active"), the color edit button (`Editor/Gui/Interaction/ColorEditButton.cs:109`), and the infinity slider overlay (`Editor/Gui/Interaction/InfinitySliderOverlay.cs:66`). The placeholder UI sets `OpenedPopupHovered` from `IsWindowHovered()` (`Editor/Gui/MagGraph/Interaction/PlaceHolderUi.cs:316`). The canvas skips `UpdateCanvas` entirely when the flag is set (`MagGraphCanvas.Drawing.cs:60`).

The canvas reads `FrameStats.Last`, not `Current`. That is a one-frame lag: an overlay announces itself in frame N and the canvas yields in frame N+1.

Two more mouse details. Fence selection uses `IsWindowHovered(AllowWhenBlockedByPopup | ChildWindows)` (`Editor/Gui/MagGraph/Ui/MagGraphView.cs:405-411`), and the comment at line 406 explains why: crossing a child window must not cancel an active fence. And the placeholder keeps its own drag alive while its input stays active (`PlaceHolderUi.cs:235-241`).

### Trace: Dragging a Color Swatch Over the Canvas

Let's follow one press-and-drag.

1. Frame N: the user presses on a color edit button drawn over the canvas. The button becomes the active item and sets `FrameStats.Current.OpenedPopupCapturedMouse = true` (`ColorEditButton.cs:109`).
2. Frame N+1: `ScalableCanvas` evaluates arbitration. `FrameStats.Last.OpenedPopupCapturedMouse` is true, so `isAnotherItemActive` is true and the canvas does not start a pan or selection.
3. The graph canvas also skips `UpdateCanvas` (`MagGraphCanvas.Drawing.cs:60`). Nodes underneath do not become the active item.
4. The user releases. The button stops setting the flag. One frame later the canvas reacts normally again.

If the user instead right-drags on empty canvas, `_draggedCanvas` is set to this canvas, and the pan follows the cursor even beyond the window edge because of `|| isPanning`. No other canvas can claim that drag until it ends.

---

## Text Input: What Must Happen When a Field Opens?

Text fields are where both problems meet, so tixl handles them with a small set of habits. The reference is `Editor/Gui/MagGraph/Interaction/PlaceHolderUi.cs`.

**Focus on open, once.** A `_focusInputNextTime` flag calls `SetKeyboardFocusHere()` a single time (`PlaceHolderUi.cs:92-96`, `152-157`). Calling it every frame would steal focus back from the user. Rename fields follow the same habit (`Editor/Gui/MagGraph/Interaction/SectionRenaming.cs:61-64`, `RenamingOperator.cs:46,53`).

**Use a plain InputText and let the guard do the work.** The placeholder uses `ImGui.InputText` (`PlaceHolderUi.cs:180-183`). Once it is active, `IsContextValid()` blocks default shortcuts, and `KeyboardActions` blocks copy and paste.

**Disable ImGui keyboard navigation during search.** `DrawUtils.DisableImGuiKeyboardNavigation()` clears `NavEnableKeyboard` (`Editor/Gui/UiHelpers/DrawUtils.cs:72-77`). The traced code shows the clearing, not the motivation; the likely reason (inferred, not verified at runtime) is to stop ImGui's own nav from competing with the search list's key handling. Callers: the legacy `SymbolBrowser.cs:69`, `Editor/Gui/Input/SearchableDropDown.cs:95`, `InputWithTypeAheadSearch.cs:125`, and `ResourcePathInputWithSearch.cs:131`.

**Enter and Escape are hard-coded.** Enter creates the node (`PlaceHolderUi.cs:206-212`). Escape cancels via `IsKeyDown` (`PlaceHolderUi.cs:223-233`). Section rename closes on Escape, on a click outside, or when both inputs lose focus (`SectionRenaming.cs:105-109`). `RenamingOperator.cs:34-37` is guarded by `!IsAnyItemActive() && !IsAnyItemFocused()`, and its Enter handling carries the comment "TODO: Should be keyboard action". These keys are plain `IsKeyPressed` checks, so they are not rebindable.

---

## Gotchas

> Labels below: **verified** means confirmed in the traced source. **Inferred, not verified at runtime** means a conclusion from reading code that nobody has observed running.

1. **KeyBinding.Clone resets flags (verified in source; runtime impact unverified).** `KeyBinding.Clone()` sets `_flags = KeyActionHandling.Flags.None` (`KeyBinding.cs:59-65`). `KeyMap.Clone` clones every binding (`KeyMap.cs:81-87`) and is used by the keymap editor and by `KeyMapSwitching.cs:148`. Reading this, cloned keymaps may lose their focus and hover guards. We have not verified whether the active keymap is ever a clone at poll time, so treat the impact as unknown.
2. **Global conflict check flags a deliberate share (inferred, not verified at runtime).** The shortcut editor's check is key-combo-only, so it should report `C` as "Already used", even though the factory map shares `C` between `InsertKeyframe` and `CameraFocusSelection` on purpose. We read this from the code paths above and did not observe the warning.
3. **Window-move id looks like an active item.** `SetupOutputView.Board.cs:1441` notes "Not IsAnyItemActive: a press on empty window space makes the window's move-id the active item". A blanket `IsAnyItemActive()` guard can therefore trip on a plain click on empty window space (inferred, not verified at runtime for other windows). That site uses a narrower check instead.
4. **ImGui 1.91 asserts on zero-size InvisibleButton.** Nodes clamp to 1px (`MagGraphCanvas.DrawNode.cs:183`).
5. **ImGui 1.91 forbids item-level hover flags in IsWindowHovered.** `ScalableCanvas.cs:244-245` is the in-code note. This is why the canvas flag list looks the way it does.
6. **Keyboard nav can tab into string inputs.** `Editor/Gui/Graph/ParameterPopUp.cs:89` sets `NoNavInputs` unless an item is already active, so Tab cannot jump into unfocused string inputs.
7. **Frame lag.** Reading `FrameStats.Last` means overlay and canvas disagree for one frame at the start of an interaction.
8. **Hard-coded keys skip the guard.** Enter and Escape handlers use `IsKeyPressed` directly, so `IsContextValid()` never sees them.

---

## Rust / dear-imgui-rs Translation

You do not need tixl's static classes to reproduce the behaviour. Rust gives you better places to put the state. The API names below are sketches of the shape, so check them against the dear-imgui-rs version you use.

### Step 1: An Action Enum With Per-Action Flags

Make the context a property of the action definition, not scattered across call sites. A `const` table keeps flags out of cloned keymaps entirely, which sidesteps the Clone gotcha by construction.

```rust
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub enum Action { Duplicate, Delete, OpenBrowser, InsertKeyframe, CameraFocus, CameraForward, /* ... */ }

bitflags::bitflags! {
    #[derive(Clone, Copy)]
    pub struct ActionFlags: u8 {
        const NEEDS_FOCUS   = 1 << 0;
        const NEEDS_HOVER   = 1 << 1;
        const ALLOW_WHEN_ITEM_ACTIVE = 1 << 2;
        const PRESS_ONLY    = 1 << 3;
        const HOLD_ONLY     = 1 << 4;
    }
}

impl Action {
    pub const fn flags(self) -> ActionFlags { /* match self { ... } */ ActionFlags::empty() }
}
```

The `match` in `flags()` is exhaustive, so adding an action without choosing its flags is a compile error. tixl's array sized by `__Count` cannot give you that.

### Step 2: One context_valid Function

Keep a single guard so there is exactly one place to reason about. It takes the flags, reads ImGui state for the current window, and applies the same three rules in the same order.

```rust
use dear_imgui_rs::{sys, HoveredFlags, Ui};

/// dear-imgui-rs 0.8 has no safe flags variant of IsWindowFocused
/// (`Ui::is_window_focused()` always passes 0), so the ChildWindows check
/// tixl relies on needs one small wrapper over the sys call.
fn window_or_child_focused() -> bool {
    unsafe { sys::igIsWindowFocused(sys::ImGuiFocusedFlags_ChildWindows as i32) }
}

fn context_valid(ui: &Ui, flags: ActionFlags) -> bool {
    if flags.contains(ActionFlags::NEEDS_FOCUS) && !window_or_child_focused() { return false; }
    if flags.contains(ActionFlags::NEEDS_HOVER)
        && !ui.is_window_hovered_with_flags(HoveredFlags::CHILD_WINDOWS) { return false; }
    if !flags.contains(ActionFlags::ALLOW_WHEN_ITEM_ACTIVE) && ui.is_any_item_active() { return false; }
    true
}
```

**Binding gap worth knowing:** checked against the dear-imgui-rs 0.8.0 source, `Ui::is_window_focused()` calls `igIsWindowFocused(0)` and there is no `is_window_focused_with_flags`, while hover does have `is_window_hovered_with_flags(HoveredFlags)`. Without the wrapper above, a "needs focus" check silently ignores focus inside child windows (for example a canvas drawn in a child region), which is exactly the case tixl's `ChildWindows` flag exists for. (`dear_imgui_rs::sys` re-exports `dear-imgui-sys`, where `igIsWindowFocused(flags: ImGuiFocusedFlags)` takes a `c_int` and `ImGuiFocusedFlags_ChildWindows = 1`.)

### Step 3: Poll Triggered() Inside the Owning Window

Poll from inside the window's draw closure, so focus and hover refer to that window, exactly as in tixl. The keymap becomes a lookup from `Action` to key combos, and `triggered` walks the combos for that action.

```rust
fn triggered(ui: &Ui, keymap: &KeyMap, action: Action) -> bool {
    keymap.combos(action).iter().any(|c| context_valid(ui, action.flags()) && c.is_triggered(ui, action.flags()))
}

// inside the canvas window's draw:
if triggered(ui, &app.keymap, Action::Duplicate) { app.duplicate_selection(); }
```

### Step 4: A Frame-Level overlay_captured_mouse Flag

Replace `FrameStats.Current/Last` with a small struct in your app state that you swap at the end of each frame. Overlays write `current`, canvases read `last`. You keep tixl's one-frame lag, but it is now explicit and testable.

```rust
#[derive(Default)]
struct FrameFlags { overlay_captured_mouse: bool, overlay_hovered: bool }

struct App { frame_last: FrameFlags, frame_current: FrameFlags, /* ... */ }

fn end_frame(app: &mut App) {
    app.frame_last = std::mem::take(&mut app.frame_current);
}
```

### Step 5: An App-Level Drag Owner

Instead of a static `_draggedCanvas`, store an owner id in app state. Only the owner may continue a drag, and anyone may start one only when no owner exists. Statics break with multiple viewports or multiple app instances in tests, and an `Option` makes the "who owns the mouse?" question answerable in one place.

```rust
#[derive(Clone, Copy, PartialEq, Eq)]
enum DragOwner { Canvas(CanvasId), Overlay(OverlayId) }

impl App {
    fn try_begin_drag(&mut self, who: DragOwner) -> bool {
        if self.drag_owner.is_none() { self.drag_owner = Some(who); true } else { false }
    }
    fn end_drag(&mut self, who: DragOwner) {
        if self.drag_owner == Some(who) { self.drag_owner = None; }
    }
}
```

The canvas pans when `(interactable || self.drag_owner == Some(me))`, which is the same `|| isPanning` trick, now backed by an explicit owner.

### What to Improve Over tixl

- **Context-aware conflict detection.** Give each action a context tag (graph, timeline, inspector) and have the shortcut editor flag a conflict only when two actions share a key and an overlapping context. Then the shared `C` stops producing a false warning, and truly colliding bindings in one context still get caught.
- **Use `io.want_text_input` as an extra guard.** Add `&& !io.want_text_input` to `context_valid` for non-opted-out actions. `IsAnyItemActive()` also fires for sliders and drags, and (per the gotcha above) for window-move ids. `WantTextInput` says precisely "a text field wants characters". Using both gives text-field safety without relying on one blunt signal. tixl uses `WantTextInput` in four local sites but never centrally.
- **Route Enter and Escape through actions.** tixl's own TODO points at this. Make them actions with `ALLOW_WHEN_ITEM_ACTIVE` where needed, so they are rebindable and discoverable.
- **Keep flags out of cloneable data.** The `const fn flags()` above means a cloned keymap cannot lose them.

---

## Summary

- Declare actions in a flat enum, bind them to key combos in a keymap, and poll `Triggered()` where you draw.
- One guard, `IsContextValid()`, applies focus, hover, and "no active item" rules in that order. The caller's window scope is the context.
- Mouse arbitration is item order plus a one-frame overlay flag plus a single drag owner.
- Text fields stay safe because an active `InputText` trips the default guard. Focus once on open and disable ImGui keyboard nav during search.

## Next Steps

For how the graph state machine interprets these inputs, see [the state machine chapter](../maggraph/07-state-machine.md). For the Tab-driven browser flow end to end, see [the interaction browser chapter](../maggraph/11-interaction-browser.md). For the concrete shortcut list, see [keyboard interaction](../maggraph/13-interaction-keyboard.md), and for general ImGui idioms see [ImGui patterns](../maggraph/B-imgui-patterns.md).
