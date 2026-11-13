# Chapter 09: Windows, Docking and Layouts - Who Owns the Rooms?

> *A window is easy to open and hard to bring back exactly where the user left it.*

---

## The Problem: Windows That Forget Where They Lived

Start with a fixed editor: a graph, a preview, an inspector. Three windows, three `begin`/`end` pairs, one hard-coded arrangement. That works until the first user asks for the things every tool-style editor eventually grows. They want to dock the inspector beside the graph, hide the preview, open a second preview, switch to a clean "presentation" arrangement with one key, and have their layout come back tomorrow. Some also want a different arrangement per project.

Dear ImGui helps with part of this. It can dock windows and it can serialize that docking into an ini blob. It does not know what a "second preview" is, which windows exist, which arrangement the user prefers, or when it is safe to swap one arrangement for another. Those answers belong to the application, and if you leave them scattered through draw code you end up with seventeen windows that each reinvent visibility, focus and sizing.

This chapter traces how tixl answers those questions with three pieces: a `Window` base class that owns the begin/end ceremony, a `WindowManager` that owns the list, and a `LayoutHandling` layer that owns saved arrangements. At the end we translate the pattern for a Rust editor on dear-imgui-rs 0.8 that has a fixed three-window layout today and will need docking later.

**Mental model: a hotel with a front desk.** Each window is a room. ImGui is the building: it knows the floor plan (the dock tree) and can write it down. The `WindowManager` is the front desk. It keeps the guest list, knows which rooms are occupied, and hands out room names. A saved layout is a rooming list the desk can pin up on request. The catch: the list refers to rooms by name, not by the number on the door, so a renamed room is a room the list no longer recognizes. Keep that in mind, because it drives most of the gotchas below.

> **Scope note.** All paths are relative to `visual-programming/tixl/`. Two concrete single-instance windows are covered elsewhere and not restated here: [the symbol library](../windows/01-symbol-library.md) and [the namespace tree](../windows/02-namespace-tree.md). For why window titles double as ImGui ids, see [chapter 05](05-id-stack-and-widget-identity.md). For why the ini text must be loaded before `NewFrame`, see [chapter 08](08-frame-loop-fonts-and-dpi.md). Claims marked **inferred** come from reading code, not from running it.

---

## What Does the Window Base Class Take Off Your Hands?

`Window` (`Editor/Gui/Windows/Window.cs`) is an abstract class with a small surface: `Draw()` (`:36`), the abstract `DrawContent()` (`:221`) that subclasses fill in, and `GetInstances()` (`:32`). Think of it as a recipe with blanks. The base class does the begin/end ceremony, and the subclass only writes the part between.

`Draw()` pushes a `ChildBg` style, then calls `DrawAllInstances()` if `AllowMultipleInstances` is set (`:39`), otherwise `DrawOneInstance()`. The interesting work is in `DrawOneInstance` (`:63-175`). Reading it top to bottom, each step solves a small, specific annoyance:

1. **Hidden means skipped.** It returns early when `!Config.Visible` (`:67`). Nothing is drawn and nothing is submitted to ImGui.
2. **Size only on the first show.** On the first visible frame (tracked by `_wasVisible`, `:70`) it calls `SetNextWindowSize(WindowSizeOverride * UiScaleFactor)` (`:72`) and optionally centers the window (`CenterOnAppearing`, `:75-79`). Later frames leave the size alone, so the user's resizing and ImGui's saved ini size win.
3. **Border depends on docking.** Border width is 0 when docked and 2 otherwise (`:89`). It reads `IsWindowDocked` from the previous frame (`:264`), because, as the code puts it, you only know if you are docked after `Begin`.
4. **The close button writes your visibility.** `ImGui.Begin(title, ref Config.Visible, flags)` takes the visibility bool by reference, so the tab's close button flips `Config.Visible` directly (`:96-98`). If `MayNotCloseLastInstance` is set and only one instance is visible, a non-closable overload is used instead (`:93-97`).
5. **Header cannot leave the screen.** The window position is clamped so X and Y are at least 0 (`:119-123`), which keeps the title bar reachable. Only the top-left is protected. Right and bottom edges are not rescued (reading of the code).
6. **Content cannot drag the window.** Content sits inside `BeginChild("inner", ..., NoMove)` (`:129-139`), so a drag that starts on content does not move the window. `InnerBackgroundColor` gives each window its own background (`:28`, `:133-135`).
7. **A per-window id check** runs after content (`:141-147`); [chapter 05](05-id-stack-and-widget-identity.md) covers it.
8. **`End()` is unconditional** (`:158-160`). ImGui 1.91 requires `End` after `Begin` even when `Begin` returns false.
9. **Closing is explicit.** When the window closes, `Close()` runs and `_wasVisible` is re-armed so `CenterOnAppearing` works again next time (`:162-169`).

The persistent state is a tiny public-field class, `WindowConfig { Title, Visible }` (`:254-261`), shaped for JSON. Note that `Title` is doing two jobs: it is the ImGui window name and the serialization key. We come back to that.

---

## How Do Several Instances of One Window Type Coexist?

Some windows make sense once (a library browser). Others make sense many times (an output view pinned to different nodes, a parameter panel locked to a different selection). tixl flags the second kind with `AllowMultipleInstances` and gives each copy its own `WindowConfig`.

Three details make multi-instance work.

**Unique titles from a static counter.** An output window builds its title as `OutputPrefix + _instanceCounter` (`Editor/Gui/Windows/Output/OutputWindow.cs:31,38`). The parameter window does the same with `ParametersPrefix` (`Editor/Gui/Windows/ParameterWindow.cs:37-38`). The prefixes are "Graph View##", "Output View##" and "Parameters##" (`Editor/Gui/Windows/Layouts/LayoutHandling.cs:161-163`). The double hash is the trick. ImGui hides everything after `##` from the label but still uses it for the id, so the user sees "Output View" on every tab while ImGui sees "Output View##1", "Output View##2" and so on.

**A copy of the list each frame.** `DrawAllInstances` copies the instance list into `_instancesToDraw` before iterating (`Window.cs:227-244`). The list is reused, so the copy does not allocate. The reason is practical: a window's own draw code may add or remove instances (a "New Output" click, a close), and mutating a list you are iterating is a bug in any language.

**Menu entries that match.** Multi-instance windows get a "New X" menu item that calls `AddAnotherInstance()`. Single-instance windows get a plain Visible checkbox (`Window.cs:192-219`).

---

## Why Does Focusing a Window Take Twenty Frames?

Here is the surprising one. "Bring this window to the front" sounds like one call. In a docked editor it is not, and `Window.cs:51-57` explains why in a doc comment.

If the target window is a background tab in a dock node, `Begin` returns false for it. That means its content never runs, so a plain `SetWindowFocus()` inside `DrawContent` can never execute. The request has to come from outside, and it has to be issued at the `Begin` call of the target. There is a second wrinkle: on the frame a window is created, focus can be consumed before docking has resolved, so a single request is lost.

tixl's answer is a retry counter. `RequestWindowFocus()` sets `_focusRequestFramesLeft = 20` (`:58-61`). While the counter is above zero, the window issues `SetNextWindowFocus` before `Begin` (`:84-87`). Once `Begin` returns true, the counter resets to zero. Otherwise it decrements (`:100-107`). Callers are one-liners, for example `Editor/Gui/Windows/HelpWindow.cs:58` and `Editor/Gui/Windows/ConsoleLogWindow.cs:342`.

Let's trace what happens when the console wants attention while it sits as a hidden tab behind the graph:

1. Some code calls `RequestWindowFocus()`. The counter becomes 20.
2. Next frame, the console's `Draw` runs. It is visible but not the selected tab, so it issues `SetNextWindowFocus` and calls `Begin`.
3. If ImGui selects the tab, `Begin` returns true and the counter resets. Done.
4. If the request was swallowed (the creation-frame case), `Begin` returns false, the counter drops to 19, and the next frame tries again.
5. After at most 20 frames it gives up. A window that never becomes selectable does not retry forever.

The pattern generalizes: **a request flag with a bounded retry, owned by the window, consumed at its own `Begin`.**

---

## What Does the WindowManager Add on Top?

`WindowManager` (`Editor/Gui/Windows/Layouts/WindowManager.cs`) is deliberately plain. It holds a flat `List<Window>` of 17 windows: Variations, Output, Graph, Parameter, SymbolLibrary, AssetLibrary, Exploration, Render, IoView, Performance, Help, Console, Utilities, GuidedFeatureTests, Settings, ProjectSettings and Welcome (`:85-104`). There is no registry, no plugin discovery and no dependency graph. Adding a window means adding a line.

Its jobs, in order of how often they matter:

- **Draw everything.** `Draw()` processes layout shortcuts and toggle actions, calls `UpdateAppWindowSize()`, then draws every window (`:23-61`).
- **Wait before applying a layout.** `TryToInitialize` does nothing until `ImGui.GetFrameCount() >= 2` (`:78-83`), then `ReApplyLayout()` loads the last used layout index (`:107`, `:112-115`). The first frames are left alone so ImGui and the windows can establish themselves.
- **React to resizes.** If `DisplaySize` changes, it calls `LayoutHandling.UpdateAfterResize` (`:159-168`).
- **Enumerate honestly.** `GetAllWindows()` expands multi-instance windows and GraphWindow instances into the full list (`:117-136`).
- **Toggle by type.** `ToggleWindowTypeVisibility<T>` only acts when there is exactly one instance (`:170-177`). `ToggleInstanceVisibility<T>` flips all instances to match the first (`:143-157`).

The menu is built from the same list (`WindowManager.MenuBar.cs:11-40`). Every window gets its `DrawMenuItemToggle` except Settings, ProjectSettings, GuidedFeatureTests, Welcome and Help. A separator follows, then an "Output Window" toggle that mirrors `ShowSecondaryRenderWindow`, another separator, and finally `LayoutHandling.DrawMainMenuItems()`.

The key insight is that the manager has no layout knowledge of its own. It only knows names, visibility and order. The arrangement lives in ImGui's dock tree, which is the next piece.

---

## How Does Docking Get Switched On, and Who Saves It?

Docking is one call per frame and one config flag. `ImGui.DockSpaceOverViewport()` runs every frame before `WindowManager.Draw()` (`Editor/Gui/T3Ui.Update.cs:96-99`), and `DockingEnable` is set at startup (`Editor/UiContentDrawing/WindowsUiContentDrawer.cs:79`). The editor does **not** set `ViewportsEnable`: all ImGui windows stay inside the one OS window.

The less obvious choice is that the editor sets `IniFilename = null` (`WindowsUiContentDrawer.cs:280`). ImGui's automatic `imgui.ini` is turned off, and the app saves and loads ini text itself. Why bother? **Inferred**, from what the layout system needs: one auto-saved file cannot provide ten named slots, per-project layouts, a version tag, a window-visibility sidecar, or swapping a whole arrangement at runtime.

### The Mailbox: Handing Ini Text to the Frame Loop

Loading an arrangement means calling `LoadIniSettingsFromMemory`. That is only safe at one moment: before `NewFrame`, when no window is mid-draw (see [chapter 08](08-frame-loop-fonts-and-dpi.md)). But the code that wants to apply a layout (a keypress handler, a menu item, a project load) runs in the middle of a frame.

tixl solves this with a mailbox. Anyone who wants to apply a layout writes the ini text into `Program.NewImGuiLayoutDefinition` (`Editor/Program.cs:433`). The frame loop checks the mailbox at the top of the frame and consumes it at `WindowsUiContentDrawer.cs:143-147`, before `NewFrame`. It is the same idea as leaving a note at the front desk: you do not walk into the room mid-meeting, you leave the note and the desk delivers it between meetings.

### What a Layout Contains

A saved layout is a JSON file, `layout{N}.json`, in `SettingsDirectory/Layouts` (`LayoutHandling.cs:336-338`). Its shape is `Layout { WindowConfigs, ImGuiSettings, ImGuiVersion }`. `ImGuiSettings` is the string from `ImGui.SaveIniSettingsToMemory()` (`:224-242`, `:301-311`). Saving also records the slot in `UserSettings.Config.WindowLayoutIndex`.

So a layout has two halves that must agree. ImGui's half says which window names sit in which dock node and at what size. The app's half says which windows exist and are visible. Neither half is enough alone.

Slots come from a `Layouts` enum: `Custom0` through `Custom9`, plus `FocusMode = 11` and `SkillQuest = 12` (`:282-296`). F1 to F10 load a slot and Ctrl+F1 to F10 save one (menu `:43-76`, actions `:254-280`).

---

## Trace: Pressing F3

Let's follow a layout load from keypress to pixels.

1. `WindowManager.Draw()` sees the F3 action and asks `LayoutHandling` to load one of the `Custom` slots (the exact F-key to slot numbering is not traced here).
2. `ApplyLayout` (`LayoutHandling.cs:165-222`) takes that slot's saved `layout{N}.json` content and matches each saved `WindowConfig` to a live window **by Title**.
3. If a saved config has no matching window, it creates one. For the three multi-instance types it picks the type from the title prefix: GraphWindow, OutputWindow or ParameterWindow (`:176-197`).
4. Windows with no saved config are hidden (`:204-212`).
5. It writes the layout's ini text into the mailbox and bumps a change counter (`:215-218`).
6. At the top of the next frame the mailbox is consumed before `NewFrame` (`WindowsUiContentDrawer.cs:143-147`), ImGui loads the dock tree, and every window lands in its saved node.

One more rule keeps this honest: window size is applied only on first show. After an OS window resize, `UpdateAfterResize` re-applies the configs (`LayoutHandling.cs:78-91`).

---

## Can Layouts Travel With a Project?

Yes, and the design is careful about not dirtying the project. `ProjectView.SaveWindowLayoutToProject` (`Editor/UiModel/ProjectHandling/ProjectView.cs:420-449`) runs only when `UserSettings.Config.SaveWindowLayoutsWithProjects` is on. It stores three things on the root `SymbolUi`: the ImGui ini text, the ImGui version, and a `Dictionary<title,bool>` of window visibility. It compares against what is already stored first, and calls `FlagAsModified` only when something changed (`:439-448`). Without that check, merely opening a project would mark it unsaved.

Restoring (`:467-503`) sets visibility first. Then it writes the ini mailbox only if the saved ImGui major.minor equals the running one (`:493-501`). If versions differ, it skips silently and the user keeps their current arrangement.

### Why Versions Matter

The global layouts have the same concern. Layouts saved before ImGui 1.91.6 are deleted and replaced with defaults (`LayoutHandling.cs:108-128`, `:318`). The comment explains why: old dock entries would be "silently dropped, leaving windows undocked". The failure mode is quiet, which is why the version tag exists. Per-project layouts choose the opposite remedy: skip rather than delete, because the project's data is not the editor's to destroy.

---

## What Is Focus Mode, and How Is It Different From Fullscreen?

Focus mode is a layout plus a UI state snapshot. `UiConfig.ToggleFocusMode` (`Editor/Gui/Windows/Layouts/UiConfig.cs:14-47`, `:113-119`) saves the current UI state, pins the output as the graph background, hides the menu, title bar, toolbar and timeline, and loads the `FocusMode` layout. Leaving reverses it: layout index and UI visibility come back (`:53-57`, `:93-100`), then output pinning and background (`:64-78`). A sibling, `ToggleAllUiElements`, hides everything without changing the layout (`:81-91`).

That is separate from OS fullscreen. `ProgramWindows.HandleFullscreenToggle` (`Editor/App/ProgramWindows.cs:70-85`) fullscreens the window on its current display. The stored screen index can go stale after a monitor is unplugged and replugged (reading of the code).

A second output surface is also not an ImGui feature. `ProgramWindows.Viewer` is a separate OS window that draws a texture, not an ImGui viewport (`WindowsUiContentDrawer.cs:259-269`; `.agentic/Plans/Plan_MultiViewport.md:55-56`).

### The Multi-Viewport Plan

tixl has a written plan for real ImGui viewports (`.agentic/Plans/Plan_MultiViewport.md:24-30`): one ImGui context, a main window plus N secondary viewports, closing the main window exits, secondary windows share the D3D11 device but own their swap chains, raw Win32 `CreateWindowEx` for Wine and macOS safety, and `[UnmanagedCallersOnly]` PlatformIO callbacks. Layout JSON would gain monitor and rect data plus a version bump (`:48`). Non-goals include fullscreen on secondary viewports and per-viewport menus (`:13-19`). It is a plan, not shipped code, and it is a good reminder of how much platform work hides behind one config flag.

---

## What Can Go Wrong? Gotchas

> Labels: **verified** means confirmed in the traced source. **Inferred** means concluded from reading code, not observed at runtime.

1. **Titles are identity (verified in code; consequence inferred).** The raw title string is the ImGui window id, the dock-node membership key in the ini, and the JSON key in both `WindowConfig` and the per-project visibility map. There is no `###` stable-id split. Renaming a window orphans its dock slot in every saved layout and project: it would appear floating and its `Visible` flag would be lost.
2. **Counter reconciliation after load (unverified).** Instance titles come from static counters. We did not verify how the counter is reconciled with titles loaded from a layout, so a collision or gap after load is plausible but unchecked.
3. **Only top-left is clamped (verified).** `Window.cs:119-123` clamps X and Y to at least 0. A window saved on a larger display can still sit off the right or bottom edge after a resize.
4. **Begin false is normal (verified).** `End()` must run anyway (`:158-160`). Skipping it on a hidden tab is an assert, not a no-op.
5. **Border flicker risk (inferred).** Docked state comes from the previous frame (`:89`, `:264`), so the first frame after docking or undocking uses the old border width.
6. **Silent skips (verified).** Both a version-mismatched project layout and an unmatched dock entry fail without a message. The user just sees a different arrangement.
7. **Ini needs the right moment (verified, see [chapter 08](08-frame-loop-fonts-and-dpi.md)).** Loading mid-frame is unsafe, which is the whole reason for the mailbox.
8. **Stale screen index (inferred).** Fullscreen uses the window's current display, but a stored screen index goes stale after a replug.

---

## How Do We Build This in Rust with dear-imgui-rs?

> Everything below marked **Recommendation** is a suggestion for our editor, not something tixl does. API names were checked against dear-imgui-rs 0.8.0.

### What the Crate Gives You

The docking surface lives in `src/dock_space.rs`: `Ui::dockspace_over_main_viewport(&self) -> Id` (`:197`), a `_with_flags` variant (`:164`), `dock_space(&self, id, size) -> Id` (`:278`), `dock_space_with_class` (`:231`), `set_next_window_dock_id` (`:332`) and `_with_cond` (`:304`), `set_next_window_class(&WindowClass)` (`:357`), `get_window_dock_id` (`:386`) and `is_window_docked` (`:411`). Ini handling is on `Context` (`src/context.rs`): `load_ini_settings(&mut self, data: &str)` (`:591`) and `save_ini_settings(&mut self, buf: &mut String)` (`:600`), which appends, so clear the buffer first. `set_ini_filename` takes an `Option` (`:253`); passing `None` writes a null pointer into `io.IniFilename`, which disables the automatic `imgui.ini` exactly as tixl's `IniFilename = null` does (verified in the crate source). Config flags are `ConfigFlags::DOCKING_ENABLE` and `VIEWPORTS_ENABLE` (`src/io.rs:111,113`), and `want_save_ini_settings` is at `io.rs:373`. Multi-viewport is a Cargo feature.

One gap matters: a grep found **no DockBuilder functions**. You cannot build a default dock tree programmatically through safe bindings, so ship factory layouts as ini text.

### Step 1: A Window Trait and Manager, Even for Three Windows

**Recommendation.** Do this before docking arrives. Even with graph, preview and inspector, a trait gives you menu toggles, visibility and focus requests in one place, and the later move to docking only changes what the manager does around `begin`. This sketch shows the shape; the exact builder calls depend on your dear-imgui-rs window API.

```rust
pub trait EditorWindow {
    /// Stable id: shown title and identity are separate (see chapter 05).
    fn id(&self) -> &str;            // e.g. "Graph###graph"
    fn draw_content(&mut self, ui: &Ui, app: &mut AppState);
}

struct WindowSlot {
    window: Box<dyn EditorWindow>,
    focus_frames_left: u8,           // retry counter, tixl uses 20
}

struct WindowManager {
    slots: Vec<WindowSlot>,
    visible: HashMap<String, bool>,  // app-owned, keyed by stable id
}
```

The trait is the Rust form of the recipe with blanks. The app owns the `visible` map, so it can be saved with a layout instead of living only inside ImGui.

### Step 2: Always Pair Begin and End, and Own the Focus Retry

**Recommendation.** Mirror tixl's rule: `End` runs after every `Begin`, including when the window is collapsed or a background tab. In Rust, prefer the closure or token style the crate offers so the pairing is enforced by scope rather than by discipline. For focus, keep tixl's bounded counter, owned by the slot and consumed where the window is begun.

```rust
fn draw_window(ui: &Ui, slot: &mut WindowSlot, open: &mut bool, app: &mut AppState) {
    if slot.focus_frames_left > 0 {
        // issue the "focus next window" call here, before begin
    }
    let shown = /* begin(slot.window.id(), open) ... draw_content ... end */ false;
    if shown { slot.focus_frames_left = 0 }
    else if slot.focus_frames_left > 0 { slot.focus_frames_left -= 1 }
}
```

The placeholder comments are deliberate. The point of the snippet is the counter logic: reset when `begin` reports the window is showing, decrement otherwise. The `open: &mut bool` mirrors tixl's `ref Config.Visible`, so the tab close button updates your visibility map directly.

### Step 3: Layouts as Ini Text With a Pending Slot

**Recommendation.** Turn docking on, set the ini filename to `None`, and save layouts yourself. Because `load_ini_settings` needs `&mut Context`, it cannot run while a `Ui` is alive. That is the mailbox idea mapped onto Rust's borrow rules.

```rust
#[derive(Serialize, Deserialize)]
struct Layout {
    window_configs: Vec<WindowConfig>, // { id, visible }
    imgui_ini: String,
    imgui_version: String,
}

// App state holds `pending_layout: Option<Layout>`.
// Frame loop, before new_frame:
if let Some(layout) = app.pending_layout.take() {
    ctx.load_ini_settings(&layout.imgui_ini);   // needs &mut Context
    app.windows.apply_visibility(&layout.window_configs);
}
let ui = ctx.new_frame();
```

Anything that wants a layout sets `pending_layout` and returns. The loop applies it at the one safe point. For saving, clear a `String`, call `save_ini_settings`, and store the result next to the window configs.

### Step 4: Choices to Make Early

**Recommendations**, each a direct response to a tixl gotcha:

- **Stable ids from day one.** Use `"Graph###graph"` style titles or an enum mapped to ids, so labels can change without orphaning saved layouts. This avoids gotcha 1.
- **A version field and a reset policy.** Decide now what happens on mismatch: tixl deletes global layouts and skips project ones. Pick one on purpose rather than dropping silently.
- **Project layouts live with the project.** Write them only when they differ from what is stored, so opening a project does not mark it modified.
- **Clamp saved positions to the current display on load.** tixl clamps only the top-left; clamp all edges.
- **Factory layouts as ini text.** With no DockBuilder in the bindings, bundle default arrangements as strings, and keep a "reset layout" command that loads one.
- **Keep multi-viewport out of v1.** It is a Cargo feature, but tixl's own plan shows the platform surface (swap chains, native window creation, per-monitor data). A secondary output as a separate texture-drawing window, as tixl ships today, is the cheaper first step.

### What to Improve Over tixl

- **Separate identity from label** so the rename problem cannot occur.
- **Return a result from layout apply** (applied, skipped for version, missing windows) so silent skips become visible messages.
- **Reconcile instance counters on load** explicitly, since tixl's behavior there is unverified.

---

## Summary

- A `Window` base class owns the begin/end ceremony: visibility via the close button, first-show sizing, header clamping, unconditional `End`.
- Multi-instance windows get unique ids through `##` suffixes and are drawn from a per-frame copy of the list.
- Focus requests retry for up to 20 frames because background dock tabs never run their content.
- Layouts are ini text plus window configs, delivered through a mailbox before `NewFrame`, versioned, and optionally stored per project.

## Next Steps

Read [chapter 05](05-id-stack-and-widget-identity.md) for why titles act as ids, and [chapter 08](08-frame-loop-fonts-and-dpi.md) for why ini loading must precede `NewFrame`. For two concrete windows that plug into this machinery, see [the symbol library](../windows/01-symbol-library.md) and [the namespace tree](../windows/02-namespace-tree.md).
