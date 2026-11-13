# Chapter 05: ID Stack and Widget Identity - Who Is This Button, Really?

> *ImGui has no widget objects. A button is a string you hash this frame and hash again next frame, and hope you get the same number.*

---

## The Problem: Two Buttons, One Name

Picture a node graph with fifty nodes. Each node draws an invisible button over its rectangle so you can hover and drag it. You write `InvisibleButton("##op", size)` inside the node loop, and it works for exactly one node. The second node's button gets the same label, so ImGui hashes it to the same id. Hover and drag state now belong to "whichever `##op` ImGui saw first". Drag one node and its neighbour may light up, or nothing moves.

ImGui has no widget objects to tell the buttons apart. Between frames it remembers only a few ids: which one is hovered, which one is active, which one has focus. Everything else is rebuilt each frame from your draw code. Identity therefore comes from a hash of the label combined with an **ID stack**, and the stack is yours to manage. A widget's id is its label hashed against every `PushID` scope currently open.

A different question, covered elsewhere: [node-instance-identity](../../../../../insights/node-instance-identity.md) is about saved identity (which node on disk is which). This chapter is about per-frame widget identity (which button under the mouse is which). The two meet in one place: tixl derives widget ids from the saved ids, so the on-disk Guid ends up inside the per-frame hash.

**Mental model: street addresses.** A label is a house number. "12" is not an address until you say which street. `PushID` is the street name: inside `PushID(nodeA)`, house "12" is one place, and inside `PushID(nodeB)` it is another. Collisions happen when two houses share a number on the same street. Wrong-house bugs happen when the street name changes between visits, for example when you name it after a list position and the list reorders.

tixl has about 192 `PushID` sites and no written convention for any of this. This chapter reads what the code actually does, sorts it into a taxonomy, and translates the useful parts for a Rust editor on dear-imgui-rs, where the borrow checker can enforce what tixl leaves to habit.

> **Scope note.** Paths are relative to `visual-programming/tixl/`. Related reading: [Chapter 02: input routing and focus](02-input-routing-and-focus.md) (it uses the `##op` button), [Chapter 04: retained state](04-retained-state.md) (where saved ids become view state), and [ImGui patterns in MagGraph](../maggraph/B-imgui-patterns.md).

---

## What Does the Hash Actually Combine?

Three inputs make up a widget id. Knowing them explains every pattern below.

1. **The label text.** Everything after `##` is hashed but not displayed. Everything before `###` is displayed but not hashed (only the part from `###` on is).
2. **The ID stack.** Each `PushID` mixes a value in. `PopID` removes it.
3. **The current window.** Every window has its own stack root, so identical labels in two windows never collide.

Item three matters later: the stack is **per window**. A push in one window and a pop in another is a bug, and the menu gotcha below is exactly that.

---

## How Does tixl Pick What to Push?

A survey of `Editor/` finds 192 `PushID` and 194 `PopID` occurrences in 92 files each. Some pops are commented out (for example `Editor/Skills/Ui/SkillMapEditor.cs:38` and `Editor/Gui/Windows/SymbolLib/SymbolLibrary.cs:529-532`). The values fall into six families.

| Family | Example | Notes |
|--------|---------|-------|
| Guid hash (dominant) | `Editor/Gui/MagGraph/Ui/MagGraphCanvas.DrawNode.cs:182` `ImGui.PushID(item.Id.GetHashCode());` | Also `BooleanUi.cs:49`, `AnimValueUi.cs:64` (`SymbolChildId`), `SymbolLibrary.cs:832` (`symbol.Id`), `AssetLibrary.Draw.cs:348` (`asset.Id`) |
| Summed hashes | `Editor/Gui/InputUi/VectorInputs/FloatVectorInputValueUi.cs:47` `PushID(inputSlot.Parent.SymbolChildId.GetHashCode() + inputSlot.Id.GetHashCode())` | Also `:58`, legacy `GraphNode.cs:425,650`, `DrawNode.cs:1184` |
| Int indices | `DopeSheetArea.cs:118` (loop index), `AudioDeviceSelector.cs:108` (`deviceIndex++`) | `TableView.cs:212` `fieldIndex * 1000 + componentIndex`; `SetupOutputView.Board.cs:1014` `1000 + segment` |
| Enum casts | `Editor/Gui/Styling/CustomComponents.Buttons.cs:168,192,214` `(int)icon` | One id per icon kind |
| Strings | `Editor/Gui/Interaction/ColorEditPopup.cs:395-538` ("h", "s", "v", "a", "r", "g", "b") | Also data names: `FormInputs.cs:124` `label`, `ProjectsPanel.cs:94` `package.DisplayName` |
| Object-identity hashes | `Editor/Gui/OpUis/UIs/ValueUi.cs:71` `instance.GetHashCode()` | Also `ParameterWindow.cs:804`, `ValueLabel.cs:26-27` `inputSlot.GetHashCode()` |

(Under `Editor/Gui/...` unless a full path is given.)

Two things stand out. First, the dominant choice is the right one: the Guid of the thing being drawn. The graph, sections (`MagGraphCanvas.DrawSection.cs:33`), the symbol library, timeline clips (`TimeClipItem.cs:69`) and parameters (`ParameterWindow.cs:815`, `inputSlot.Id.GetHashCode()`) all key their rows by a stable id. Second, the long tail is mixed, and the last row is the fragile one. Whether those types override `GetHashCode` is unverified; if they do not, the hash is derived from object identity, which changes whenever the object is recreated.

### Is There a Rule Behind the Six Families?

> **Stated rule vs. code**
>
> | Stated rule | What the code does |
> |-------------|--------------------|
> | None. `.agentic/AGENT_INSTRUCTIONS.md` has nothing on ImGui ids, and `.agentic/Reviews/FEATURE_REVIEW.md:103` mentions ImGui rules but not ids. | Conventions exist only as scattered code comments (quoted throughout this chapter). Six families of push values coexist. |
>
> Unlike chapters 01 and 02, there is no rule to audit. The practice is what the comments teach.

---

## Why Do Some Rows Use the Index and Others the Guid?

The deciding question is: **what happens to this row's id when the list changes?**

**Stable-key rows** use a domain id. Reorder the list, filter it, delete the row above, and the surviving rows keep their ids, so hover, drag and open-popup state follow the right item. The node graph, sections, symbol library, timeline clips and parameters all work this way.

**Index-keyed rows** use the position. They are fine while the list never changes, and wrong when it does: the id now names a slot, not an item. The index-keyed sites are `DopeSheetArea.cs:107-118`, `Editor/Gui/Windows/Variations/VariationThumbnail.cs:30` (ActivationIndex), `Editor/Gui/Windows/SnapshotControllerGrid.cs:105`, and two search lists, `Editor/Gui/Input/SearchableDropDown.cs:153` (the **filtered** index) and `Editor/Gui/Input/InputWithTypeAheadSearch.cs:195`. A filtered index is the sharpest case: type one letter and every row's id shifts to a different item. For a transient dropdown that is harmless (inferred, not verified at runtime); for a list with drag state it would not be.

Position is sometimes the right key, for two reasons the code documents:

- **Names collide.** `AudioDeviceSelector.cs:107` says "Seed the ID from the index: devices can share a display name, which ImGui flags as conflicting IDs."
- **Rows share a definition.** `DrawNode.cs:1183`: "Multi-input rows share the same input definition, so the index is needed for a unique ID". The id there is `inputDefinition.Id.GetHashCode() + MultiInputIndex` (`:1184`). `Editor/UiModel/InputsAndTypes/InputValueUi.cs:218` pushes the multi-input index the same way.

The rule that falls out: **use the domain id when one exists, add an index only when the domain gives you nothing unique.** Index-only is for positional lists whose order is the identity.

---

## How Does a Per-Node Push Fix Every Label Inside?

Let's trace the opening problem through tixl's answer.

1. `DrawNode.cs:182` calls `ImGui.PushID(item.Id.GetHashCode())` before drawing a node. The street now has the node's name.
2. `DrawNode.cs:183-187` clamps the invisible button size to at least 1, because ImGui 1.91 asserts on a zero-size button.
3. `DrawNode.cs:188` draws `InvisibleButton("##op", ...)`. Its id is "##op" hashed under this node's street, so fifty nodes produce fifty different ids from one literal.
4. `DrawNode.cs:212` pops. The whole body between 182 and 212 is one scope.

The `##` prefix is the "hidden label" idiom: the button needs a name to hash but has nothing to display. It is common across the editor.

The same logic scales up. `DrawSection.cs:30-33` carries the comment that ImGui 1.91.2 has an ID-conflict guard, so "##sectionHeader" and "##resize" must not collide between sections. The section's `PushID` is what makes the repeated literals safe.

---

## How Do You Change a Label Without Losing the Widget?

The label is both text and identity, which is a problem when the text is live. A button that shows the current value gets a new hash every time the value changes. The hover and active state attached to the old hash is gone, so a drag can break mid-gesture.

The `###` suffix solves this: everything before it is displayed, only `###` and after is hashed. About six sites use it.

- `Editor/Gui/Windows/OutputSetup/SetupParameterView.cs:1472-1473`. The comment reads: "Stable "###" id so the button keeps its identity as its label changes." Then `ImGui.Button(ResolveTargetLabel(current) + "###pickTarget", ...)`.
- `Editor/Gui/Interaction/SingleValueEdit.cs:104,225` builds `FormatValueForButton(ref value) + "###button"`. Here the button text is the live value being dragged, so this is exactly the case.
- `Editor/Gui/OutputUi/DataSetViewCanvas.cs:138`.

`###` has a second use. `Editor/Gui/Dialog/ExitDialog.cs:21-22` notes "ImGui 1.90 rejects empty popup ids; use ### to keep the title bar visually empty", and opens `"###ExitDialog"`. An empty visible title and a non-empty id are two separate things, and `###` is how you say so.

One helper builds unique labels globally. `Editor/Gui/UiHelpers/UIControlledSetting.cs:25` declares `private static ushort _countForUniqueID = ushort.MaxValue;` and `:48-49` build `$"##{label}{_countForUniqueID--}"` or `$"{label}##{_countForUniqueID--}"`. The id is minted once at construction from a decrementing global counter. It wraps after about 65k constructions (inferred from the `ushort` type, not observed). It works because instances are long-lived; it would not work for per-frame creation.

---

## How Does a Push Get Balanced?

Every `PushID` in tixl is a manual pair. `Editor/Gui/UiHelpers/ImGuiScopes.cs` offers `StyleScope` and `ChildWindowScope` (lines 8-78) but no ID scope, so nothing pops on early return or exception. `DrawNode.cs:182` and `:212` are typical.

The safety net is a runtime check per window, at `Editor/Gui/Windows/Window.cs:141-147`:

```
var idBefore = ImGui.GetID(0);
DrawContent();
var idAfter = ImGui.GetID(0);
if (idBefore != idAfter)
    Log.Warning($"Inconsistent ImGui-ID after rendering {this}  {idBefore} != {idAfter}");
```

The trick is that `GetID(0)` hashes against whatever the stack looks like now. If a push is missing its pop inside `DrawContent`, the two values differ. It runs inside the window's "inner" child, once per window, and it only logs a warning: it does not assert, and it cannot tell you which of the many sites is at fault. It also cannot catch a push and pop that are both present but swapped around a window switch, because each window's stack is separate.

No actual imbalance was found in the sites checked, but not all 192 were audited. `SymbolLibrary.cs` has 4 `PushID` and 5 `PopID` lines including commented ones; the balance there is not verified.

One more oddity. `ParameterWindow.cs:804-836` pushes the instance hash, then the input id twice (`:815`, `:821`), and pops at `:823` and `:834`. It is redundant but balanced.

---

## What Breaks When a Push Straddles Two Windows?

`Editor/Gui/Styling/CustomComponents.Menus.cs:230-232` contains the best comment in the whole subject, quoted in full:

> "No PushID here: when the submenu opens, BeginMenu switches to the child window before we could pop, so a PushID/PopID pair would straddle two per-window id stacks ("Missing PopID()"). The label (plus ##id for uniqueness) is the menu's id; the style-color stack is global, so its pops are safe."

The lesson has two parts. A menu or popup `Begin` can change the current window under you, so a push made before it and a pop made after it hit different stacks. And ImGui has several stacks with different scopes: the ID stack is per window, the style-color stack is global. Pairs that are safe for one are not safe for the other.

A second hot-reload story is at `CustomComponents.Menus.cs:148-149`: "The label seeds the imgui id too: int ids alone can collapse to 0 after hot reload (initializers of newly added static fields don't run), which made all items conflict." Pure int ids carry no text to fall back on; a label carries its own entropy.

---

## Can a Vanishing Id Break an Interaction?

Yes, and tixl has a documented case. An archived plan (`.agentic/Plans/archive/Plan_TimelineSelectionUI.md:84`) records that one `InvisibleButton` per bucket, keyed by `PushID(stableId)`, cancelled a drag when buckets merged and the id vanished. The active-item id pointed at a button that no longer existed. The fix was a single strip-wide button with a constant id.

The takeaway is that a stable key is only stable if the *thing* survives. When items merge, split or disappear mid-gesture, the widget should own a larger region and derive hit-testing from data instead of per-item widgets.

---

## How Do Popups Fit In?

Popup ids hash against the **current** stack too. `OpenPopup("x")` and `BeginPopup("x")` must therefore run under the same stack, or they refer to different ids and the popup silently never shows.

tixl uses literal string ids (for example "customFormats" at `FloatVectorInputValueUi.cs:164,169` and "pickOutput" at `Editor/Gui/MagGraph/Interaction/OutputPicking.cs:37`) and sometimes constants (`ColorEditPopup.PopupId`). It leans on the row's stack for per-item distinction: `SetupParameterView.cs:1459` says "The row's ImGui ID stack keeps each item's popup distinct."

Window titles are the same idea at the top level. `Editor/Gui/Windows/Window.cs:34` defines `WindowDisplayTitle => Config.Title`, passed raw to `ImGui.Begin` (`:97-98`). There is no `###`. Titles are fixed strings or prefix plus counter (`Editor/Gui/Windows/Output/OutputWindow.cs:31`), docking identity is the title string, and the title is serialized (`Window.cs:257`). Renaming a window therefore changes its docking identity (inferred from the code path, not verified at runtime).

---

## What Else Could Go Wrong?

Here is the checklist of street-name mistakes and other traps, collected from the sections above.

> **verified** means confirmed in the traced source; **unverified** means inferred from reading code.

1. **Summed hashes can collide (unverified in practice).** `a.GetHashCode() + b.GetHashCode()` is commutative, so swapping the two parts gives the same id, and unrelated pairs can add to the same sum. The sites at `FloatVectorInputValueUi.cs:47,58`, `GraphNode.cs:425,650` and `DrawNode.cs:1184` do this. No collision was observed. Nested pushes avoid the question.
2. **Guid hash is 32 bits (verified for the API; collision odds not measured).** `GetHashCode()` folds a 128-bit Guid into an int. Collisions are unlikely at editor scale, not impossible.
3. **Object-identity hashes are fragile (unverified).** `ValueUi.cs:71`, `ParameterWindow.cs:804` and `ValueLabel.cs:26-27` hash the object itself. Whether those types override `GetHashCode` was not checked. If not, a recreated instance gets a new id and loses hover and active state.
4. **Index keys break on reorder or filter.** See the index-keyed list above.
5. **A ushort counter wraps (inferred).** `UIControlledSetting.cs:25`.
6. **Missing pops are only warned about per window.** `Window.cs:141-147` logs and does not assert.
7. **Zero-size InvisibleButton asserts in ImGui 1.91.** Clamp to 1 (`DrawNode.cs:183-187`).
8. **Empty popup ids are rejected since ImGui 1.90.** Use `###` (`ExitDialog.cs:21-22`).
9. **`HelpUiID` is not an ImGui id.** `Editor/Gui/HelpUiIDAttribute.cs` is a help-topic tag. Do not look for id logic there.

---

## How Does This Translate to Rust and dear-imgui-rs?

These facts are checked against dear-imgui-rs 0.8.0 source.

### What Does the Rust API Give You?

`Ui::push_id<'a, T: Into<Id<'a>>>(&self, id: T) -> IdStackToken<'_>` (`src/stacks.rs:355`) returns an RAII token that pops on drop. That removes tixl's manual-pair problem for the common case: an early return still pops. `Id` is:

```rust
enum Id<'a> { Int(i32), Str(&'a str), Ptr(*const c_void) }
```

`push_id` dispatches to `igPushID_Int`, `igPushID_Str` or `igPushID_Ptr`. `From` impls exist for `i32`, `usize`, `&str`, `&String`, `*const T` and `*mut T`. There is no impl for `u64`, `u128` or `Uuid`.

### The Trap: usize Truncates

The impl is `impl From<usize> for Id { fn from(i: usize) -> Self { Id::Int(i as i32) } }`. It silently drops the upper 32 bits on a 64-bit target. If you push a 64-bit hash as a `usize`, you keep half of it and nothing warns you. This is the Rust twin of tixl's 32-bit `GetHashCode()`, except that you could choose a better key and the API quietly stops you.

### Pushing a 128-bit Node Id

Three safe options:

- **(a) Format into a stack buffer and push the `&str`.** For example the uuid crate's `simple().encode_lower(&mut [0u8; 32])`. No heap allocation, and `igPushID_Str` hashes all the bytes. This is the portable default.
- **(b) Fold to u64 and push as a pointer.** `Id::Ptr(key as usize as *const c_void)`. ImGui hashes the pointer's full bit width on 64-bit targets. The width is platform-dependent, so document the 64-bit assumption or prefer (a).
- **(c) Nested pushes of two halves.** Two `push_id` calls with `i32` or `&str` halves. Full entropy, no string.

### How Do You Keep Call Sites Off the Lossy Path?

Put the choice in one place with a `WidgetKey` newtype, so call sites cannot reach for `usize`. This sketch shows the shape; names are illustrative.

```rust
/// Stable domain id for a widget: a node, an input, a clip.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct WidgetKey(uuid::Uuid);

fn push_key<'ui>(ui: &'ui Ui, key: &WidgetKey) -> dear_imgui_rs::IdStackToken<'ui> {
    let mut buf = [0u8; 32];
    let s: &str = key.0.simple().encode_lower(&mut buf);
    ui.push_id(s)
}
```

Here is the opening problem again, solved with that helper. The token is a guard, so the scope ends where the binding does:

```rust
for node in graph.nodes() {
    let _id = push_key(ui, &node.id);   // street name = the node's saved id
    ui.invisible_button("##op", size);  // same literal, unique per node
}                                       // pop on drop
```

The saved id from the node-identity note flows straight into the per-frame hash, with no `GetHashCode()` step in between.

### Which tixl Habits Are Worth Keeping?

- **Derive widget ids from stable domain ids; index only for positional lists.** The same decision rule as tixl's stable-key rows. Where a list has duplicates by name, mix in the index as an extra nested push.
- **Nest pushes instead of summing hashes.** `push_key(node)` then `push_key(input)` gives a path, not a commutative sum, and it removes gotcha 1.
- **A live-label helper.** Wrap the `###` idiom so nobody concatenates by hand: `format!("{label}###{key}")`. A stack-buffer variant avoids the per-frame allocation; whether the `format!` cost matters in your editor is a measurement, not an assumption.
- **Window titles with `###stable`.** `"Output###output_1"` keeps docking identity when the visible title changes, which tixl's raw titles cannot do.
- **Popup ids as named consts**, opened and begun under the same stack: `const PICK_OUTPUT: &str = "pickOutput";`.
- **Keep a debug assert like `Window.cs:141-147`.** RAII tokens make imbalance rarer, but they do not stop a `std::mem::forget`, a token leaked into a struct, or the window-switch case below. In dear-imgui-rs 0.8 the probe is `ui.get_id("##id_probe")` (`get_id(&self, label: &str) -> Id`; it hashes a label against the current stack, so the same probe label before and after gives equal ids only if the stack is balanced). Compare the two in debug builds with a `debug_assert_eq!` instead of a log line.

### Does RAII Fix the Menu Problem Too?

No. tixl's menu comment (`CustomComponents.Menus.cs:230-232`) still applies. An `IdStackToken` held across `begin_menu` or `begin_popup` straddles a window switch, and the drop runs against a different window's stack. Scope the token to code that stays inside one window, push *inside* the popup's body instead of before it, and let the label carry identity at the boundary. RAII solves "forgot to pop"; it does not solve "popped on the wrong stack".

---

## What Should You Remember?

- A widget id is the label hashed against the per-window ID stack. Labels repeat; streets distinguish them.
- tixl mostly pushes the stable domain Guid, with indices where the domain gives nothing unique, and there is no written rule for any of it.
- `###` keeps identity when text is live, and also gives empty-title popups a legal id.
- Missing pops are caught per window by one `GetID(0)` before/after check, as a warning only. Menus and popups can move you to another window's stack mid-scope.
- In Rust, use RAII `push_id` tokens, a `WidgetKey` newtype, and avoid pushing 64-bit values as `usize`.

## Next Steps

For the button whose id this chapter makes unique, see [Chapter 02: input routing and focus](02-input-routing-and-focus.md). For how saved ids become the per-frame state the ids point at, see [Chapter 04: retained state](04-retained-state.md). For general ImGui idioms in the graph, see [ImGui patterns](../maggraph/B-imgui-patterns.md).