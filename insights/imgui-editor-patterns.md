# ImGui Editor Patterns: What a Large Dear ImGui Editor Teaches a Rust One

You are building a tool-style application, a node-graph editor with an inspector and a live preview, on Dear ImGui through dear-imgui-rs. The first window took an afternoon. Then the questions start. Why does dragging a slider create sixty undo entries? Why does Delete remove a node while the user is typing in a text field? Why does the canvas zoom feel jumpy? Where does selection live, when the UI forgets everything each frame?

None of these are Dear ImGui questions. ImGui gives you widgets that redraw every frame and report what happened to them. Everything above that, the conventions that make a hundred windows behave like one application, is yours to design. This note distills those conventions from tixl, whose editor is about 134,000 lines of ImGui code that has met all of these problems, and from apEx's Whiteboard UI, which met many of them a decade earlier.

The detailed evidence is in the [ImGui craft chapter set](../notes/per-framework/tixl/editor/imgui/00-index.md) (eleven chapters, each ending in a Rust translation checked against dear-imgui-rs 0.8). This note is the short version: the patterns worth adopting, adapting or avoiding, and how each maps to Rust.

---

## The Core Insight: Immediate Mode Needs Retained Spines

Think of an ImGui editor as a **stage play performed fresh every night**. The actors (widgets) improvise their lines each frame, which is what makes immediate mode so pleasant to write. But a play still needs a script supervisor who remembers what happened last night, a stage manager who decides whose cue it is, and a prop table where things are kept between scenes.

Every pattern below is one of those backstage roles: a small piece of retained structure that sits beside the immediate-mode code and gives it continuity. tixl's lesson is that each role works best as **one choke point**: one translator for edits, one guard for shortcuts, one transform for canvases. Where code goes around the choke point, bugs collect.

apEx's Whiteboard reached the same shape from the other direction: an immediate-mode API in front of retained-mode rendering ([UI patterns](../notes/per-demoscene/apex-public/patterns/ui-patterns.md), [Whiteboard](../notes/per-demoscene/apex-public/tool/ui-system.md)).

---

## Patterns to Adopt

| # | Pattern | What it solves | tixl evidence | Rust shape |
|---|---------|----------------|---------------|------------|
| 1 | **Edit-state contract** | One undo entry per gesture | Widgets return `Started / Modified / Finished`; one translator owns a single in-flight command ([ch. 01](../notes/per-framework/tixl/editor/imgui/01-edit-lifecycle-and-undo.md)) | Derive state from `is_item_activated` / `is_item_active` / `is_item_deactivated`; one `Option<InFlightEdit>` keyed by (node, param) |
| 2 | **Gesture as one macro** | Multi-node moves undo as one step | Drag start opens a macro, release commits it ([ch. 01](../notes/per-framework/tixl/editor/imgui/01-edit-lifecycle-and-undo.md)) | Snapshot originals at drag start; commit one command on release; Escape restores |
| 3 | **Actions with context flags** | Shortcuts that don't fire while typing | Each action declares needs-focus / needs-hover / allowed-while-item-active; one guard checks them ([ch. 02](../notes/per-framework/tixl/editor/imgui/02-input-routing-and-focus.md)) | Action enum + bitflags + one `context_valid`, polled inside the owning window |
| 4 | **Frame-level overlay capture flag** | Overlays and canvases fighting for the mouse | Widgets set "popup captured mouse"; canvases read last frame's value ([ch. 02](../notes/per-framework/tixl/editor/imgui/02-input-routing-and-focus.md), [ch. 07](../notes/per-framework/tixl/editor/imgui/07-popups-menus-and-drag-drop.md)) | `FrameUiState { current, last }` swapped each frame |
| 5 | **One reusable zoomable canvas** | Graph, timeline and curves sharing pan/zoom | `ScalableCanvas` serves about a dozen editors ([ch. 03](../notes/per-framework/tixl/editor/imgui/03-zoomable-canvas.md)) | `#[derive(Copy)] ViewTransform` + composed `InteractiveCanvas`, as tixl's own refactor TODO proposes |
| 6 | **Zoom-dependent level of detail** | Readable, fast canvases at any zoom | Labels above scale 0.25, thumbnails above 0.2 ([ch. 03](../notes/per-framework/tixl/editor/imgui/03-zoomable-canvas.md)) | A `lod(scale)` helper used by every draw routine |
| 7 | **Ids, resolved each frame** | Stale references after delete, reload, recompile | Selection and commands hold id paths, not objects ([ch. 04](../notes/per-framework/tixl/editor/imgui/04-retained-state.md)) | Store ids; resolve to `Option<&T>` per frame; prune missing |
| 8 | **Change counters for derived data** | Rebuilding caches only when inputs change | Selection `ChangeCounter`, layout refresh flags, gated list rebuilds ([ch. 04](../notes/per-framework/tixl/editor/imgui/04-retained-state.md), [ch. 10](../notes/per-framework/tixl/editor/imgui/10-per-frame-performance.md)) | A `u64` generation bumped by the command executor; views compare and rebuild |
| 9 | **Semantic palette + one style mapping** | Themeable, consistent colors | `UiColors` roles mapped into ImGui style in one function ([ch. 06](../notes/per-framework/tixl/editor/imgui/06-theming-and-widget-library.md)) | `Palette` struct with serde; `apply_theme(&Palette, &mut Style)` |
| 10 | **A house widget library** | Consistent rows, menus, icon buttons | `FormInputs` rows with label column, reset-to-default and help marker ([ch. 06](../notes/per-framework/tixl/editor/imgui/06-theming-and-widget-library.md)) | A `form_row` helper and menu helpers; feature code doesn't call raw popup APIs |
| 11 | **Dialogs drawn every frame, opened by flag** | Popups opening in the wrong ID scope | `ShowNextFrame()` sets a flag; the dialog opens itself inside its own draw ([ch. 07](../notes/per-framework/tixl/editor/imgui/07-popups-menus-and-drag-drop.md)) | `Dialog::show()` / `draw()` returning `DialogResult<T>` |
| 12 | **Hover-help broker** | Help panels that follow the cursor | Producers record (topic, frame); the help window accepts this or last frame ([ch. 07](../notes/per-framework/tixl/editor/imgui/07-popups-menus-and-drag-drop.md)) | A tiny per-frame struct; explicit `help_target(ui, id)` calls |
| 13 | **Layouts as app-owned data** | Named layouts, per-project layouts, version safety | In-memory ini plus window configs plus version, applied before `NewFrame` ([ch. 09](../notes/per-framework/tixl/editor/imgui/09-windows-docking-and-layouts.md)) | `load_ini_settings` from a pending slot before `new_frame`; `set_ini_filename(None)` |
| 14 | **Focus requests that retry** | Surfacing a background dock tab | Focus request repeats for up to 20 frames until `Begin` succeeds ([ch. 09](../notes/per-framework/tixl/editor/imgui/09-windows-docking-and-layouts.md)) | `request_focus` counter in the window manager |
| 15 | **Always-on frame diagnostics** | Seeing performance regressions as they happen | Frame-time bar in the menu bar, stall watchdog with overlay ([ch. 10](../notes/per-framework/tixl/editor/imgui/10-per-frame-performance.md)) | Frame-time bar; debug-build allocation counter per frame |

## Patterns to Adapt

These work in tixl but depend on something Rust either gives you for free or makes awkward.

- **Scoped styling.** tixl wrote an `IDisposable` style scope and then used it in two files, against 347 raw `PushStyleColor` calls ([ch. 06](../notes/per-framework/tixl/editor/imgui/06-theming-and-widget-library.md)). dear-imgui-rs already returns RAII tokens from `push_style_color`, `push_style_var`, `push_font` and `push_id`. Don't wrap them back into manual push/pop helpers.
- **Widget identity.** tixl pushes Guid hash codes and sometimes sums two hashes ([ch. 05](../notes/per-framework/tixl/editor/imgui/05-id-stack-and-widget-identity.md)). In dear-imgui-rs, `push_id` accepts `i32`, `usize`, `&str` and pointers, and **`From<usize>` truncates to 32 bits**. Push a 128-bit node id as a stack-formatted string, or as a pointer-width value, and nest pushes instead of summing hashes.
- **Focus guards.** tixl's central guard uses `IsWindowFocused(ChildWindows)`. dear-imgui-rs 0.8 has no safe flags variant (`is_window_focused()` passes 0), so a small `unsafe` wrapper over the sys call is needed ([ch. 02](../notes/per-framework/tixl/editor/imgui/02-input-routing-and-focus.md)).
- **DPI.** tixl uses physical pixels, rebuilds fonts at the scaled size, and multiplies every literal by a global scale factor, but never rescales its base style ([ch. 08](../notes/per-framework/tixl/editor/imgui/08-frame-loop-fonts-and-dpi.md)). Pick one model, keep an unscaled base style, and rebuild from it on change. `ImGuiStyle_ScaleAllSizes` is reachable through `dear_imgui_rs::sys`.
- **Drag and drop.** tixl marshals strings into native memory and also keeps a static copy for non-ImGui consumers ([ch. 07](../notes/per-framework/tixl/editor/imgui/07-popups-menus-and-drag-drop.md)). Keep a typed payload enum in editor state; let the ImGui payload carry at most a tag.

## Patterns to Avoid

- **Statics as state.** The in-flight edit command, the focused project view, the dragged canvas, the UI scale factor and font scale are all static in tixl, and the chapters keep finding bugs at their edges. In Rust, pass state explicitly; the borrow checker will push you there anyway.
- **Object references in UI structs.** Every stale-reference comment in tixl sits next to a held reference. Hold ids.
- **Copy-to-be-safe iteration.** tixl's symbol library calls `ToList()` twice per row per frame to guard against modification during iteration ([ch. 10](../notes/per-framework/tixl/editor/imgui/10-per-frame-performance.md)). Collect actions during the loop and apply them afterwards.
- **No cancel path.** tixl's drags and text edits commit on Escape ([ch. 01](../notes/per-framework/tixl/editor/imgui/01-edit-lifecycle-and-undo.md)). Hold the pre-edit snapshot and make Escape restore it.
- **Titles as identity.** tixl window titles are raw strings, so renaming a window orphans its dock slot in saved layouts ([ch. 09](../notes/per-framework/tixl/editor/imgui/09-windows-docking-and-layouts.md)). Use `"Label###stable_id"` from the first version.

---

## The Meta-Lesson: Encode Conventions, Don't Just Write Them

tixl writes its UI rules down for contributors and coding agents, and that document is a valuable source in its own right. Auditing it against the code ([ch. 11](../notes/per-framework/tixl/editor/imgui/11-stated-rules-vs-code.md)) shows a consistent split: **rules backed by a type or helper hold; rules that live only in prose drift.** Some prose rules are already stale (a font "enum" that is a class, a glyph range that was widened, an undo rule the code contradicts), and the review checklist checks only a narrow slice of them.

A Rust editor can move most rules out of prose:

| Rule kind | Prose version | Encoded version |
|-----------|---------------|-----------------|
| Balanced pushes | "Always pop what you push" | RAII tokens (already in dear-imgui-rs) |
| Scaled pixels | "Multiply every literal by the scale factor" | A logical-pixel newtype accepted by your helpers |
| Theme colors only | "Never construct colors in draw code" | A palette token type with no public raw constructor outside theme code |
| Use the helpers | "Prefer the context-menu helper" | clippy `disallowed_methods` for raw popup APIs outside the helper module |
| Undo discipline | "Mutations go through commands" | A command trait as the only mutation path, with an explicit "already applied" commit |
| Label style | "Title Case, three dots for 'needs input'" | A unit test that scans menu labels |

Keep prose for what genuinely needs judgment, and generate stale-prone facts, like glyph ranges and font roles, from the code that defines them.

## Related

- [ImGui craft in tixl](../notes/per-framework/tixl/editor/imgui/00-index.md): the eleven-chapter evidence base
- [Node instance identity](./node-instance-identity.md): saved identity of graph nodes (as opposed to per-frame widget identity)
- [apEx UI patterns](../notes/per-demoscene/apex-public/patterns/ui-patterns.md): hybrid immediate/retained design from a demotool
- [Node-graph editor UX](../notes/themes/node-graphs/node-graph-editor-ux.md): editor UX compared across tools
