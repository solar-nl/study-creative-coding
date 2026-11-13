# Chapter 06: Theming and the Widget Library - Push, Pop, and Hope

> *A color is a decision. A `PushStyleColor` without its `Pop` is a decision you forgot to take back.*

**Part of:** [ImGui Craft in tixl](00-index.md)

---

## The Problem: A Hundred Files Who Each Know What "Muted" Looks Like

Dear ImGui styles through a stack. You push a color, draw some widgets, pop the color. Push and pop must balance, and nothing in the language checks that they do. Multiply this by a few hundred call sites and you get two separate problems. The first is drift: every file that pushes `(0.5, 0.5, 0.5, 1)` for "secondary text" has its own opinion of what secondary text looks like. The second is leakage: one missing pop and every widget drawn afterwards, in every window, inherits a stray color or font until ImGui asserts.

tixl attacks the first problem seriously and the second one mostly by convention. It has a themeable semantic color table, a small set of font roles, and a house widget library (`CustomComponents`, `FormInputs`) that every window is supposed to use instead of raw ImGui calls. It also has a scoped-style type that makes push/pop balance automatic, but almost nobody uses it. This chapter traces both halves, checks the written rules against the code, and translates the lessons for a Rust editor on dear-imgui-rs, where the binding already hands you the safe form for free.

**Mental model: a paint shop with a color chart.** A good shop does not mix "a bit of gray" every time. It has a chart of named paints (Text, TextMuted, StatusError), and every job refers to the chart. Repainting the building means editing the chart, not visiting each room. The push/pop stack is the paint roller: you dip, you roll, you must wipe it clean before the next room. tixl built the chart well. The roller hygiene is left to the painters' discipline.

> **Scope note.** Paths are relative to `visual-programming/tixl/`. Related reading: [input routing and focus](02-input-routing-and-focus.md) for the guard-by-convention pattern this chapter echoes, [the zoomable canvas](03-zoomable-canvas.md) for `UiScaleFactor` and UI scale, [popups, menus and drag-drop](07-popups-menus-and-drag-drop.md) (chapter 07) for popup and context-menu behavior, and [ImGui patterns](../maggraph/B-imgui-patterns.md) for general idioms.

---

## What Is the Color Table, and Why Are Fields Named Like Roles?

`Editor/Gui/Styling/UiColors.cs` is a static class of mutable `public static Color` fields (`UiColors.cs:11-150`), grouped as Text, Window Background, Inputs, Various, Status, Output setup and Widgets. The names describe roles, not shades: `Text`, `TextMuted`, `TextDisabled`; `BackgroundPopup`, `BackgroundGaps` (labeled "App / Menu Background"), `BackgroundInputField`. A button author never asks "what gray?" They ask "what is the input field background?"

Two details make this table more than a bag of constants:

- **Every field carries metadata.** `[T3Style.Hint(GroupTitle, DisplayName, Description)]` sits on each field (`UiColors.cs:18`, attribute defined at `T3Style.cs:14`). The theme editor reads these attributes to build its own UI (`ColorThemeEditor.cs:123`, `:219`), so adding a color means adding one field and it shows up in the editor.
- **Field names are serialization keys.** The comment at `UiColors.cs:13-15` says "never rename". Renaming a field silently orphans every saved theme.

### Status Colors Carry Meaning

The Status group encodes what a value is doing, and the meanings are used consistently across the UI: `StatusAnimated` is orange and means time-driven (`UiColors.cs:132-133`), `StatusAutomated` is blue and means driven or linked (`:114-115`), `StatusControlled` is green (`:117`), and `StatusAttention` is magenta (`:123`). This matches the table in `.agentic/AGENT_INSTRUCTIONS.md` (L166-171).

There is a catch, shown in the first row of the table below: three of these status colors are currently the same color.

### Where Do the Written Rules and the Code Disagree?

| Stated rule | What the code does |
|-------------|--------------------|
| Status colors express distinct meanings (AGENT_INSTRUCTIONS L166-171) | `StatusAttention`, `StatusWarning` and `StatusError` are all `new(203, 19, 113, 255)` (`UiColors.cs:123-130`). Three meanings, one pixel value, so they are not yet visually distinct. The names are separate, so a theme can split them later. |
| Use `StylizedText` for font-plus-color text (`AGENT_INSTRUCTIONS.md:230`) | The helpers themselves repeat `PushFont` + `PushStyleColor` + `TextUnformatted` by hand (`CustomComponents.Menus.cs:38-42`, `:62-66`) instead of calling `StylizedText` (`CustomComponents.cs:412-418`). `FormInputs.AddIcon` and `DrawHelpMarker` push `Icons.IconFont` by hand (`FormInputs.cs:1116`, `:1169`). |
| Prefer the context-menu helper over raw popups (AGENT_INSTRUCTIONS L219-255) | Partly followed. Raw `BeginPopupContextItem/Window` remains in `Editor/Gui/Hub/ProjectsPanel.cs:199,302,357` and `Editor/Gui/Windows/AssetLib/AssetLibrary.ToolsPopup.cs:18`. Helper adoption is the common path, not the only one. |
| Use three periods for "needs more input" because "the font atlas only rasterises a fixed glyph range" (AGENT_INSTRUCTIONS L307-308, L351-353) | Stale or now a pure style policy. The atlas build adds General Punctuation 0x2010-0x205E (which covers the ellipsis), arrows, 0x2600-0x26FF (the warning sign) and Dingbats 0x2700-0x27BF, with a doc comment (`UiContentUpdate.cs:98-104`, comment at `:79-84`). The "..." is still the convention, but the technical reason no longer holds. |
| Fonts are selected from a "Fonts enum" (AGENT_INSTRUCTIONS L210) | There is no enum. `Fonts` is a static class of `ImFontPtr` properties: `FontLarge`, `FontNormal`, `FontBold`, `FontSmall`, `Code` (`Fonts.cs:5-12`). The wording is loose, and the difference matters for the mutable-state gotcha below. |

---

## How Does a Theme Reach the Screen?

Semantic colors only pay off if changing the table changes the app. The path is short, and worth tracing end to end.

1. **A theme is a data file.** `ThemeHandling.ColorTheme` holds a `Name`, an `Author`, a `Dictionary<string, Vector4> Colors` and a `Dictionary<string, ColorVariation> Variations` (`ThemeHandling.cs:259-277`). Each theme is one JSON file at `ThemeFolder/<name>.json` (`:32-49`, `:201`).
2. **Shipped themes are read-only.** If a user file has the same name, the user file wins, and defaults are copied on save (`ThemeHandling.cs:84-117`).
3. **`ApplyTheme` writes the statics.** It uses reflection over the fields of `UiColors` and `ColorVariations` and assigns each static from the theme dictionary (`ThemeHandling.cs:151-187`).
4. **Missing keys fall back to the factory theme** (`:153-154`). The code comment gives the reason: themes saved before a color was added would otherwise keep the previous theme's color.
5. **Notification.** `ApplyTheme` sets `FrameStats.UiColorsChanged` and calls `T3Style.Apply()`.
6. **`T3Style.Apply()` bridges to ImGui.** It maps semantic colors by hand into `style.Colors[...]`: `FrameBg` takes `BackgroundInputField` (`T3Style.cs:46`), `Header` takes `BackgroundActive.Fade(0.5f)` (`:80`). It also sets metrics: `FramePadding` is 7,4 (`:30`), `WindowPadding` is 0 (`:90`), rounding is 0 (`:96-99`).

Legacy key renames are handled in `ThemeHandling.cs:189-199`, which is the escape hatch for the "never rename" rule. The theme editor saves through `SetThemeAsUserTheme` and `SaveTheme` (`ColorThemeEditor.cs:49`, `:66`).

A few things stand out:

- **Reflection is the glue.** The fields are the schema, the hint attributes are the UI description, and reflection loads and saves them. That keeps the file small, at the cost of the "never rename" hazard.
- **The wrapper forces field-by-field writes.** The comment at `T3Style.cs:9-10` says the .NET ImGui wrapper exposes only get-accessors for `ImGuiStyle`, so `Apply` assigns individual fields instead of replacing the struct.
- **Code relies on a metric.** `T3Style.cs:87-89` depends on `WindowPadding` being 0. Change the metric and that code breaks silently.

### Per-Type Colors: Variations Instead of More Colors

Operator types have base colors, and the UI needs several shades of each (background, connection line, highlight). Rather than adding three colors per type, `ColorVariations.cs:11-20` defines named `ColorVariation(brightness, saturation, opacity)` factors (`OperatorBackground`, `ConnectionLines`, `Highlight`). `ColorVariation.Apply` (`ColorVariation.cs:29-37`) scales the type color in HSV. Variations are themeable too, which is why `ColorTheme` has the second dictionary. `Fade` and `Mix` live on the color type in `Core/DataTypes/Vector/Color.cs` (`Fade` at `:527`, `Mix` at `:128`), not in `ColorExtensions.cs`, which has only `GetStyleColor` (`:8`).

The key insight: a theme author edits three small factors and every type color follows, instead of hand-picking dozens of shades.

---

## What Happens When Push/Pop Relies on Convention?

Now the roller hygiene. tixl does have a safe form. `Editor/Gui/UiHelpers/ImGuiScopes.cs` defines `StyleScope : IDisposable` (`:8-59`). You hand it `Coloring[]` and `Styling[]` records (`:82-83`), it counts what it pushed, and `Dispose` pops exactly that many. `ChildWindowScope` (`:61-78`) pushes `ChildBg`, `WindowPadding` and `ChildRounding`, calls `BeginChild`, and on dispose calls `EndChild` and pops. With C# `using`, balance is automatic.

Adoption tells the story. Measured by search (counts are approximate, and not every call was audited):

| Mechanism | Occurrences | Files |
|-----------|-------------|-------|
| `StyleScope` / `ChildWindowScope` | about 4 constructions | 2 (`Editor/Gui/OutputUi/DataSetViewCanvas.cs`, `Editor/Gui/Windows/ParameterSettings.cs`) |
| `PushStyleColor` under `Editor/` | 347 | about 102 |
| `PushFont` | about 199 | about 108 |
| Pop calls (`PopStyleColor`, `PopStyleVar`, `PopFont`) | about 615 | about 162 |

The scoped form exists and is nearly unused. Nearly everything else is manual push and manual pop.

### Why Don't People Use the Scope?

The record does not make this easy, and the code shows why (inferred from reading; we have not asked the authors):

- **Style values are typed `object`.** `StyleScope` matches them through float and `Vector2` switch arms (`ImGuiScopes.cs:32-40`). A value of any other type pushes nothing but is still counted, so `Dispose` pops too many. The type system cannot catch this.
- **Arrays allocate per use.** Building `Coloring[]` and `Styling[]` each frame conflicts with the editor's no-allocation habit.
- **The convenient alternative is right there.** `PushStyleColor` is one line.

### Pseudo-Scopes and Hard-Coded Counts

When code does try to bundle pushes, it falls back to conventions of its own:

- `CustomComponents.PushToolbarIconBackground()` and `PopToolbarIconBackground()` (`CustomComponents.Buttons.cs:228-229`) toggle a static bool. A static flag cannot nest, and nothing stops a second Push without a Pop.
- `PushToolIconStyle` and `PopToolIconStyle` carry hard-coded counts (`Buttons.cs:241-266`). Edit the push list and you must remember to edit the count.
- `ContextMenuForItem` pushes four style vars and ends with `PopStyleVar(4)` (`CustomComponents.Menus.cs:26-52`).

We found no imbalance in the helpers we read. That is a credit to the authors, not to the mechanism: all 615 pops were not audited, and the safety here is care, not construction.

### A Leak You Can Point At

The font system has a concrete example of state escaping its scope. `Fonts.X.Scale` is a mutable property on a global font object. In `Editor/Gui/MagGraph/Ui/MagGraphCanvas.Drawing.cs:137` the code resets it with `Fonts.FontSmall.Scale = 1; // WTF. Some of the drawNode seems to spill out fontSize`. The rule at AGENT_INSTRUCTIONS L211 exists because of this. When a global can be changed anywhere and a symptom shows up elsewhere, a defensive reset is the only tool left.

---

## How Does Typography Work?

Fonts are roles, not sizes. `Fonts.cs:5-12` exposes five properties: `FontLarge`, `FontNormal`, `FontBold`, `FontSmall` and `Code`. They are built in `Editor/UiContentDrawing/UiContentUpdate.cs:61-74`:

| Role | Face and size |
|------|---------------|
| Normal | Inter Regular 16 |
| Bold | Inter SemiBold 16 |
| Small | Inter Regular 12 |
| Large | Inter Light 30 |
| Code | JetBrains Mono 18 |

Sizes are scaled by DPI. The atlas is cleared and rebuilt on request (`RequestFontRebuild`, `UiContentUpdate.cs:40`), and `T3Ui.UiScaleFactor` is set in the same place (`:51-54`). See [the zoomable canvas chapter](03-zoomable-canvas.md) for how that factor is consumed. Push and pop are by convention (the 199 `PushFont` sites), with no RAII wrapper.

### Icons Are a Separate Font With a Separate Drawing Path

`Editor/Gui/Styling/Icons.cs:16` defines `IconFont`, keyed by `(char)Icon` (`:25`). Most draws do not use text at all. They look up the glyph's UVs and call `drawList.AddImage(Fonts.TexID, ...)` (`:66-114`). `DrawIconOnLastItem` centers the icon and floors the position to avoid blur (`:101-114`). A couple of helpers use `PushFont(IconFont)` plus `TextUnformatted` instead (`DrawAtCursor` and `DrawInlineGlyph`, `:20-31`, `:44-51`). One more wart: the ImGui.NET glyph struct is "broken", so the code remaps its fields by hand (`:124-134`).

### Labels and Glyph Policy

AGENT_INSTRUCTIONS (L277-300) asks for Title Case with lowercase short prepositions, and (L304-308) three periods for "needs more input". The code mostly follows, with exceptions: `Editor/Gui/Dialog/WelcomeAlphaWindow.cs:243` writes "Importing…" with the real ellipsis character, and `Editor/Gui/Windows/OutputSetup/SetupParameterView.cs:129` draws "⚠ also routed to…" through `StylizedText` where an Icon would be canonical. Both work, because the atlas includes those ranges (see the rules-vs-code table above).

The icon rules (L325-335) hold up better. `IconButton` is canonical, with states Default, Emphasized, Disabled, Activated and NeedsAttention. The code gives a transparent background and a muted hover (`Buttons.cs:248-256`), no hover for Disabled (`:164-166`), and, for NeedsAttention, a separate `AttentionIconButton` (`:185`).

---

## What Is in the House Widget Library?

The widget library is where semantic colors and scoped styling are supposed to pay off. A window author calls `ToggleButton` and gets the right colors, padding, hover and tooltip without ever touching a style push.

**Buttons** (`CustomComponents.Buttons.cs`): `ToggleButton` (`:11`), `ToggleIconButton` (`:37`), `ToggleTwoIconsButton` (`:47`), `TransparentIconButton` (`:112`), `IconButton(Icon, size, ButtonStates)` (`:158`), `AttentionIconButton` (`:185`), a colored `IconButton` overload (`:207`), `RoundedIconButton` (`:273`), `StateButton` (`:291`) and `DrawCtaButton` (`:393`, `:425`, `:456`).

**Menus** (`CustomComponents.Menus.cs`): `ContextMenuForItem` (`:16`), `DrawMenuGroupLabel` (`:58`), `DrawMenuItem` (`:69`, `:80`, `:108`) and `DrawSubMenu` (`:211`).

**Tooltips** (`Tooltips.cs`): `TooltipForLastItem` (`:27`, `:67`, `:89`) and `BeginTooltip(wrapPos = 300)` (`:52`).

**Small pieces** (`CustomComponents.cs`): `SmallGroupHeader` (`:77`), `SeparatorLine` (`:102`), `HintLabel` (`:123`), `StylizedText` (`:412-418`: push font, push Text color, `TextUnformatted`, pop both) and `RightAlign` (`:438`).

### Two Menu Helper Tricks Worth Stealing

- **A static callback avoids closure allocation.** `ContextMenuForItem` stores its draw callback in a static field (`Menus.cs:45-47`), so the caller's lambda does not allocate a closure each frame. It is a per-frame allocation fix that costs re-entrancy.
- **Popups re-push `FramePadding`** (`Menus.cs:29-31`) so row height does not depend on whatever the caller had pushed. The pushed paddings elsewhere in this helper are unscaled literals, `new Vector2(6, 6)` (`:26-27`). Chapter 07 covers menus in depth.

### FormInputs: One Layout for Every Parameter Row

`Editor/Gui/Input/FormInputs.cs` is the part that makes parameter panels look uniform. Think of a spreadsheet's column grid: labels in one column, inputs in the next, optional extras at the right edge. Every row follows the same rules:

1. **Fixed label column.** `DefaultParameterIndent = 150` (`FormInputs.cs:1183`) and `LeftParameterPadding = _paramIndent * UiScaleFactor` (`:1186`).
2. **Right-aligned labels.** `DrawInputLabel` aligns the label into the column (`:914-929`).
3. **Widget start.** The input starts at `LeftParameterPadding + ParameterSpacing` (`:931-934`).
4. **Width cap.** Number inputs are capped at `MaxNumberInputWidth = 280` (`:148`).
5. **Reset button on demand.** `AppendResetButton` draws an `Icon.Revert` `IconButton` only when the value differs from the default (`:1154-1165`). A sentinel, `NotADefaultValue` (`:1181`), means "no default exists". `AddInt` (`:115-131`) is a compact example.
6. **Tooltip as a help-marker icon after the input** (`AppendTooltip`, `:1104`). The body is Markdown with a fixed wrap width, to avoid scrollbar reflow (`:1124-1141`).
7. **Width bookkeeping.** `GetAvailableInputSize` subtracts reset and tooltip widths (`:1081-1097`).

### A Concrete Trace: One Int Row

Let's follow what `AddInt` draws (`FormInputs.cs:115-131`) when a parameter has a non-default value:

1. The label is right-aligned into the 150-unit column, scaled by `UiScaleFactor` (`:914-929`, `:1186`).
2. The cursor moves to `LeftParameterPadding + ParameterSpacing` (`:931-934`).
3. `GetAvailableInputSize` takes the row width and subtracts the reset button and help marker widths (`:1081-1097`), then the input is capped at 280 (`:148`).
4. The input draws. The edit/undo lifecycle is [chapter 01](01-edit-lifecycle-and-undo.md).
5. Because the value differs from the default, `AppendResetButton` draws the revert icon (`:1154-1165`).
6. `AppendTooltip` draws the help marker and, on hover, the Markdown body (`:1104`, `:1124-1141`).

### Searchable Drop-Downs: Honest Comments

`SearchableDropDown` is a static class with a single static `_activeInputId` (`Editor/Gui/Input/SearchableDropDown.cs:16-30`). It closes if it has not been drawn for more than 2 frames (`:39`), which is how it detects "the user moved on" in a framework with no close event. `InputWithTypeAheadSearch.cs:16` calls itself "a single horrible hack" in its doc comment, and `ResourcePathInputWithSearch.cs:18` repeats the line. We like the honesty. It also marks where the next cleanup lives.

---

## What Could Go Wrong? Gotchas and Their Status

> **verified** means confirmed in the traced source. **Unverified** means inferred from reading and never run.

1. **Three status colors are one color (verified).** `UiColors.cs:123-130`. Users cannot tell attention from warning from error by hue alone.
2. **Count mismatch in `StyleScope` (verified in source; runtime effect unverified).** An unmatched value type pushes nothing but is counted (`ImGuiScopes.cs:32-40`), so Dispose would over-pop.
3. **Static-flag pseudo-scope does not nest (verified).** `Buttons.cs:228-229`.
4. **Hard-coded pop counts drift (verified as a pattern).** `Buttons.cs:241-266` and `Menus.cs:26-52`. Whether any site is currently out of step is unverified; we did not audit all 615 pops.
5. **Mutable global font scale (verified).** `MagGraphCanvas.Drawing.cs:137`.
6. **Inconsistent scaling (verified).** A `+10` at `FormInputs.cs:921` is not scaled, while `:1133` multiplies by the scale. On a high-DPI display the two would diverge (unverified at runtime). Unscaled `new Vector2(6, 6)` paddings at `Menus.cs:26-27` have the same shape.
7. **Renaming a color field breaks saved themes (verified by the in-code comment).** `UiColors.cs:13-15`; legacy renames are patched in `ThemeHandling.cs:189-199`.
8. **`WindowPadding` of 0 is load-bearing (verified).** `T3Style.cs:87-89`.
9. **The drop-down closes after 2 undrawn frames (verified).** A frame hitch longer than that could close it early (unverified).

---

## How Do You Build This in Rust With dear-imgui-rs?

Back to the paint shop: the goal is a chart that themes can edit and a roller that wipes itself. The checked facts first. dear-imgui-rs 0.8.0 returns RAII tokens from its push functions: `Ui::push_style_color(StyleColor, impl Into<[f32; 4]>) -> ColorStackToken` (`src/stacks.rs:65`), `push_style_var(StyleVar) -> StyleStackToken` (`:101`), `push_font(FontId) -> FontStackToken` (`:41`) and `push_id(...) -> IdStackToken` (`:355`). Each pops on drop. So the scoped form that tixl built and few adopted is the default path for you, and most of the 615-pop problem disappears, provided you do not wrap tokens back into manual helpers. The sketches below show shape, not exact signatures.

### Step 1: How Do You Keep the Chart Editable and Renames Safe?

Replace reflection and the factory-fallback with serde. A struct with explicit field names is the schema, `#[serde(default)]` supplies missing keys, and `#[serde(alias)]` handles renames, so the "never rename" rule becomes "rename and add an alias".

```rust
#[derive(Clone, Serialize, Deserialize)]
#[serde(default)] // missing keys take Palette::factory() values
pub struct Palette {
    pub text: [f32; 4],
    pub text_muted: [f32; 4],
    pub text_disabled: [f32; 4],
    pub background_popup: [f32; 4],
    #[serde(alias = "background_gaps")] // old key still loads
    pub background_app: [f32; 4],
    pub background_input: [f32; 4],
    pub background_active: [f32; 4],
    pub status_animated: [f32; 4],
    pub status_automated: [f32; 4],
    pub status_attention: [f32; 4],
    pub status_warning: [f32; 4],  // give these three distinct defaults
    pub status_error: [f32; 4],
    // ...
}
```

Struct-level `#[serde(default)]` is what replaces tixl's `FactoryTheme` fallback: a theme saved before a color existed gets the factory value for that field. This also avoids the bug tixl's comment describes, where a theme saved before a color existed would keep the previous theme's color.

### Step 2: Where Should the Chart Meet ImGui?

tixl hand-maps semantic colors into the ImGui style. Keep that mapping in exactly one function, and write it as a function of `&Palette` and `&mut Style`, so metrics like window padding sit next to the code that relies on them.

```rust
pub fn apply_theme(p: &Palette, style: &mut Style) {
    style.set_color(StyleColor::FrameBg, p.background_input);
    style.set_color(StyleColor::Header, fade(p.background_active, 0.5));
    style.set_frame_padding([7.0, 4.0]);
    style.set_window_padding([0.0, 0.0]); // code in the graph relies on this
}
```

The accessor names above are a sketch; check the style API in your version of the crate. The point is that the mapping is the only place that knows both vocabularies.

### Step 3: How Do Type Colors Get Their Shades?

`ColorVariation` ports directly as three floats with an `apply` that scales HSV. It is data, so it serializes in the theme beside the palette.

```rust
#[derive(Clone, Copy, Serialize, Deserialize)]
pub struct ColorVariation { pub brightness: f32, pub saturation: f32, pub opacity: f32 }
impl ColorVariation { pub fn apply(self, base: [f32; 4]) -> [f32; 4] { /* HSV scale */ base } }
```

### Step 4: How Do You Make the Roller Wipe Itself?

tixl's `StyleScope` fails because values are `object`. In Rust, make it a builder over typed entries and return the token bundle. Dropping the bundle pops in reverse order, so the "counted but not pushed" bug cannot exist.

```rust
struct StyleBundle<'ui> { _colors: Vec<ColorStackToken<'ui>>, _vars: Vec<StyleStackToken<'ui>> }

fn input_scope<'ui>(ui: &'ui Ui, p: &Palette) -> StyleBundle<'ui> {
    StyleBundle {
        _colors: vec![ui.push_style_color(StyleColor::FrameBg, p.background_input)],
        _vars: vec![ui.push_style_var(StyleVar::FramePadding([7.0, 4.0]))],
    }
}
```

Bind the result to a named variable (`let _s = input_scope(...)`), never `_`, or the tokens drop immediately. Drop order is not a concern: checked against dear-imgui-rs 0.8.0, each token pops exactly one entry from its own stack (`igPopStyleColor(1)`, `igPopStyleVar(1)`), and colors, vars and fonts are separate ImGui stacks, so a `Vec` dropping front to back pops the right things. Avoid per-frame `Vec` allocation on hot paths by using fixed arrays or `SmallVec`.

### Step 5: How Do You Avoid the Leaking Font Scale?

Make the role an enum and have a registry map it to a `FontId`, then expose one push that returns a token. Do not expose a mutable scale on the handle: scale belongs in atlas build, as tixl does with DPI.

```rust
#[derive(Clone, Copy)]
pub enum FontRole { Normal, Bold, Small, Large, Code }

fn push_role<'ui>(ui: &'ui Ui, fonts: &FontRegistry, role: FontRole) -> FontStackToken<'ui> {
    ui.push_font(fonts.id(role))
}
```

### Step 6: How Do You Get One Layout for Every Row?

The FormInputs layout reduces to one function that takes a label, a closure for the widget, an optional default and an optional tooltip. Compute the label column once in logical pixels times the UI scale (see [chapter 03](03-zoomable-canvas.md)), and use the same scaled value for every literal padding, which removes the `+10`-style slips.

```rust
fn form_row<T: PartialEq + Copy>(
    ui: &Ui, ctx: &FormCtx, label: &str, value: &mut T,
    default: Option<T>, help: Option<&str>,
    widget: impl FnOnce(&Ui, f32, &mut T) -> bool,
) -> bool {
    // 1. right-align label into ctx.label_col (logical px * ctx.scale)
    // 2. width = available - reset button - help marker, capped at ctx.max_input
    // 3. changed = widget(ui, width, value)
    // 4. if default.is_some_and(|d| d != *value) { revert icon button -> *value = d }
    // 5. if let Some(h) = help { help marker + tooltip with fixed wrap width }
    false
}
```

`Option<T>` replaces the `NotADefaultValue` sentinel, and the compiler forces callers to say whether a default exists.

### Step 7: How Do You Keep Glyph Rules From Going Stale?

Use an `Icon` enum and decide glyph ranges once. Put the range list, the label rules (Title Case, three periods or the real ellipsis) and the icon rules in the same module doc, so the rule and the atlas cannot drift apart the way L307-308 did. Draw icons by glyph UVs as tixl does when you need pixel-exact centering, and floor the position.

### Step 8: How Do You Enforce Label Style?

Menu labels are data. A unit test over the registered menu items can check Title Case with lowercase short prepositions, and fail the build on a violation. This turns an AGENT_INSTRUCTIONS paragraph into a gate.

### What Should You Do Better Than tixl?

- **Keep helpers token-returning.** Do not rebuild `PushToolIconStyle` with hard-coded counts or a static-bool toggle. If a helper must bundle pushes, return the bundle.
- **One `text_styled` helper, used by the other helpers.** tixl's rule exists and its own helpers skip it. Make menu and form code call it, so the rule has no exceptions to explain.
- **Distinct status defaults on day one.** Warning, error and attention should differ in the factory theme.
- **No globals that change.** The `Fonts.FontSmall.Scale = 1;` reset is what mutable shared state looks like.
- **Test theme round-trips.** Load an old-format theme with aliases and a theme missing keys, and check the result.

---

## Summary

- Semantic, role-named colors in a single table, with metadata and serialization keys, let a theme change the whole app. tixl does this well, with one flaw: three status colors share a value.
- Push/pop discipline is by convention in tixl. A scoped type exists but appears in about 2 files, against 347 `PushStyleColor` and about 199 `PushFont` sites. In dear-imgui-rs, token returns make the scoped form the default.
- A house widget library (`CustomComponents`, `FormInputs`) buys consistency, but its own helpers bypass its own `StylizedText` rule.
- Several written rules lag the code (glyph range, "Fonts enum", context-menu helper). Keep policy and implementation in one place so they cannot drift.

## Where to Go Next

[Chapter 07](07-popups-menus-and-drag-drop.md) covers popups, modals and context menus, including the helper whose adoption is partial here. For the edit lifecycle behind form inputs, see [chapter 01](01-edit-lifecycle-and-undo.md). For UI scale and the zoomable canvas, see [chapter 03](03-zoomable-canvas.md). For input guards by convention, see [chapter 02](02-input-routing-and-focus.md). For general ImGui idioms, see [ImGui patterns](../maggraph/B-imgui-patterns.md).
