# Chapter 11: Stated Rules vs. Code - Where the Map Stops Matching the Territory

> *A rules document is a map. This chapter walks the territory and notes where the map is wrong, where it is silent, and what a Rust project can do so its map stays true.*

**Part of:** [ImGui Craft in tixl](00-index.md) | [Editor Documentation](../00-architecture.md)

---

## The Problem: Rules Documents Drift, and Agents Believe Them

Every codebase that lasts long enough grows a conventions document. tixl's lives in `.agentic/AGENT_INSTRUCTIONS.md`, and it is unusually serious. It has about 225 lines of "UI Implementation Guidelines" (roughly L150-375), a Realtime Performance section (L29-40) and a State and Resource section (L41-56). A second file, `.agentic/Reviews/FEATURE_REVIEW.md`, turns part of it into a review checklist. The audience is contributors and coding agents.

Documents like this decay in a predictable way. Code changes on Tuesday, and nobody edits the prose. A convenient shortcut gets used three times, and the rule that forbids it stays unchanged. A rule is written against a version of the code that no longer exists.

For human contributors, drift is an annoyance. They notice the contradiction, ask in chat, and move on. A coding agent behaves differently. It reads "Only use values from the Fonts enum" and obeys it literally, even after `Fonts` stopped being an enum. It reads "Never mutate .A directly" and either follows the rule into awkward code or learns, from the surrounding files, that the rule is optional. Either way the document stops being a source of truth and becomes a source of noise.

This chapter audits the whole UI section against the source. Chapters 01-07 already ended with "Stated rule vs. code" boxes for the rules they touched. Here we cover every rule, group the results, and ask a more useful question than "who is wrong": **which rules stayed true, which drifted, and what separated the two?** The answer shapes how you should write conventions for your own ImGui editor, especially a Rust one.

---

## The Mental Model: A Map, Road Signs and a Guardrail

Think of the rules document as a paper map of a city. The map is accurate on the day it is printed. After that the city keeps building: new roads open, an old bridge closes, a one-way street flips direction. Travelers who follow the map literally end up at a closed bridge.

Three things can keep travelers safe:

- **Reprint the map more often.** This is the review checklist. It works only for the streets someone remembered to check.
- **Post signs at the bridge.** This is a helper function or an enum: a convention embedded where the code is written.
- **Build a guardrail.** This is a type, a compiler lint or a test. The wrong move cannot happen, or fails loudly.

The audit's central finding is that rules protected by a sign or a guardrail mostly held, while rules that exist only as paragraphs drifted. The rest of the chapter shows the evidence and then asks what a Rust project can turn from paragraphs into guardrails.

---

## Method: Sampled Spot Checks, Not an Exhaustive Audit

Be clear about what this audit is. For each rule we checked **two to four sites** in the code, chosen to include both the heavily used paths (MagGraph, the op UIs) and the newer, less polished ones. Where a rule suggested a countable pattern, we also grepped counts. The Legacy graph (`Editor/Gui/Graph/Legacy/`) is excluded except where a row says otherwise, because it is on its way out and would inflate every violation count.

That means:

- "Followed (sample)" means the sampled sites followed the rule, not that every site does.
- Counts, such as "44 constructions in 20 files", are repo-wide greps, but we inspected only the sampled files behind them.
- "Unverifiable" means we could not turn the rule into something checkable. That is a finding in itself.

Paths are relative to `visual-programming/tixl/`. The audit covers 55 rules and statements. The tables below group them by area and condense each to a verdict plus evidence.

**Reading the codes.** The last column says how the rule is held in place. **T** means a type or helper backs it. **P** means prose only. **R** means `FEATURE_REVIEW.md` covers it, **R?** means only indirectly, and a dash means the review does not mention it.

---

## The Audit: Which Rules Still Match the Code?

### Theming and colors (AGENT_INSTRUCTIONS L160-171)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Never construct `new Color(...)` in draw code (L160) | Partly followed | MagGraph and OpUis are clean. Violations at `Editor/Gui/Interaction/JogDialOverlay.cs:114,129,242,259`. 44 constructions in 20 files repo-wide. | P (`UiColors` is T), R |
| Never mutate `.A` directly (L161) | Partly followed | Followed in MagGraph. Violated at `Editor/Gui/Interaction/ColorEditPopup.cs:199,239,327,443,491,541,666`. A color editor arguably needs this, but the guide states no exception. | P, - |
| Use `Color.Mix(a, b, t)` (L162) | Followed | `Mix` and `MixOkLab` exist at `Core/DataTypes/Vector/Color.cs:128,138`. | T, - |
| Status-color table (L166-171) | Names match, values do not differ | Three status hues share one value (`Editor/Gui/Styling/UiColors.cs:123-130`). (prior chapter: [06](06-theming-and-widget-library.md)) | P, - |

The `new Color` rule shows the pattern in miniature. A `UiColors` table exists and most code uses it, but nothing stops a draw routine from writing a literal. The `.A` rule shows the other pattern: a rule with a legitimate exception that the document never mentions, so every reader has to guess whether `ColorEditPopup` is a violation or an intended carve-out.

### Scaling and pixels (L174-207)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Every pixel literal multiplied by `UiScaleFactor`. "No exceptions." (L174) | Partly followed | Unscaled tooltip padding at `Editor/Gui/MagGraph/Interaction/ConnectionHovering.cs:127` and `Editor/Gui/MagGraph/Ui/MagGraphCanvas.DrawNode.cs:348-350,700`, plus `Editor/Gui/Input/FormInputs.cs:921`. The global is mutated at `Editor/Gui/Windows/TimeLine/TimeLineCanvas.cs:119,150` and `Editor/Gui/Interaction/CurveEditPopup.cs:68-73`. Style constants are never rescaled (ch08). | P, R |
| Don't double-scale: pass `5`, not `5 * UiScaleFactor` (L178) | Unverifiable | No mechanical check exists. | P, - |
| `value / UiScaleFactor * CanvasScale` (L179) | Partly followed (prior chapter: [03](03-zoomable-canvas.md)) | | P, - |
| Threshold-cull expensive detail at low zoom (L180) | Followed in MagGraph | `CanvasScale` thresholds in `DrawNode.cs`. ([03](03-zoomable-canvas.md)) | P, - |
| Pixel alignment (L182-207) | Implemented in one place | `Editor/Gui/Windows/OutputSetup/SetupStrokes.cs`. Meanwhile `ScalableCanvas.TransformPosition` truncates instead of rounding. ([03](03-zoomable-canvas.md)) | T only in OutputSetup, - |

"No exceptions" is the strongest wording in the document, and it has the most exceptions. The rule fights convenience: a tooltip padding of `4` is easier to type than `4 * UiScaleFactor`. It also depends on global state (`UiScaleFactor` is a mutable static), which the timeline and curve code temporarily changes.

### Fonts (L210-211)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Only use values from the `Fonts` enum (L210) | **Stale** | `Fonts` is a static class (`Editor/Gui/Styling/Fonts.cs:5-12`). 431 `Fonts.Font*` uses sit within its members. ([06](06-theming-and-widget-library.md)) | T, R? |
| Font mix "Normal ~70%, Small ~20%, Bold ~5%, Large <2%" (L210) | Unverifiable | Nobody measured it. | P, - |
| Reset `Fonts.*.Scale` to 1 before returning (L211) | **Not followed** | `MagGraphCanvas.Drawing.cs:137`: `Fonts.FontSmall.Scale = 1; // WTF. Some of the drawNode seems to spill out fontSize`. One reset in the whole Gui tree and no RAII. ([06](06-theming-and-widget-library.md)) | P, R |

The comment at `Drawing.cs:137` is the most honest sentence in the audit. The author knew the rule, could not find the leak, and patched the symptom. A rule that says "remember to undo this global change" invites exactly that.

### Draw lists (L214-217)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Prefer a single draw list, z-order by call sequence (L214) | Followed | | P, - |
| Split channels only when needed, merge immediately (L215) | Followed (sample) | Small, local `ChannelsSplit` uses. | P, - |
| Emit the topmost `InvisibleButton` last (L216) | Unverifiable | ([02](02-input-routing-and-focus.md)) | P, - |
| Avoid excessive `PushClipRect` (L217) | Unverifiable | Counts look modest, but "excessive" has no threshold. | P, - |

### Helpers, menus and text (L224-273)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Check `CustomComponents` and `FormInputs` for an existing helper (L156) | Partly followed | 199 `CustomComponents.*` helper calls against 37 raw popup/`MenuItem` sites. | P, R? ("native sliders instead of FormInputs") |
| New `PushFont`/`PushStyleColor` blocks where a helper exists are a review flag (L224) | Partly followed | 131 `StylizedText` calls against 199 raw `ImGui.PushFont`. | T helper, P rule, R? |
| `StylizedText` for short labels (L230) | Partly followed | Used at `MagGraphCanvas.DrawMissingItems.cs:96`. `DrawNode.cs:359` uses `ImGui.TextColored`. | T, - |
| `ContentPanel.Begin/End` (L235) | Partly followed | Hub panels use it. Hand-rolled headers remain. | T, - |
| `DrawCtaButton` / `RightAlign` (L240-244) | Followed (sample) | `CustomComponents.cs:438`. | T, - |
| Context-menu API (L252-273) | Partly followed | Raw `BeginPopupContext*`/`MenuItem` in 6 files. Legacy `GraphView.cs` holds 28 of the 37 sites. Live code: `Editor/Gui/Hub/ProjectsPanel.cs` 3, `InputValueUi.cs` 2, `TimeClipInteractions.cs` 1. `GraphContextMenu.cs` has 39 `DrawMenuItem` calls. ([07](07-popups-menus-and-drag-drop.md)) | T, - |
| Pass `drawItems` as a static method group, not a lambda (L270) | **Not followed** | `MagGraphCanvas.Drawing.cs:308`. The signature `ContextMenuForItem(Action...)` (`CustomComponents.Menus.cs:16`) cannot enforce it. ([07](07-popups-menus-and-drag-drop.md)) | P, R (closures) |

Look at the helper numbers. The helper wins in one case (199 to 37) and loses in the other (131 to 199), yet raw calls remain in both. Nothing forbids them. A sign on the road only helps the driver who looks up: a helper that is merely *available* gets used when the author remembers it exists.

### Labels and icons (L277-358)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Check `Icons` for a baked-in glyph (L157) | Followed (sample) | The `Icon` enum is the norm (`Editor/Gui/MagGraph/Interaction/GraphContextMenu.cs:134`). One hand-rolled tool button at `Editor/Gui/Windows/AssetLib/AssetLibrary.ToolsPopup.cs:148`. | T, - |
| Title Case for every clickable command label (L277) | Followed in live code | About 30 correct labels at `Editor/Gui/AppMenuBar.cs:310-630` ("Export as Executable", "Import from JSON", "Duplicate as New Type..." at `GraphContextMenu.cs:552`). Violations only in Legacy (`GraphView.cs:687 "Arrange sub graph"`, `:769`, `:889`, `:894`). | P, - |
| Lowercase prepositions of four letters or fewer (L284-294) | Followed (sample) | "Control with Snapshots", "Open in Shader Editor". | P, - |
| Trailing `...` means more input is needed (L304) | Partly followed | Correct at `AppMenuBar.cs:310`. Status labels use it too: "Proxy Queued..." (`GraphContextMenu.cs:187`), "Importing..." (`Editor/Gui/Dialog/WelcomeAlphaWindow.cs:243`). | P, - |
| No `...` on submenu headers (L305) | Unverifiable | | P, - |
| Use three periods, not the single `…` character (L307) | **Stale** | The atlas includes `…` (`Editor/UiContentDrawing/UiContentUpdate.cs:79-104`), and the UI uses it at `Editor/Gui/Windows/Variations/VariationPicker.cs:113 "Search…"`. ([06](06-theming-and-widget-library.md)) | P, - |
| Section headers in Title Case (L310) | Unverifiable | | P, - |
| Prose keeps sentence case (L313) | Followed (sample) | `GraphContextMenu.cs:202`. | P, - |
| `IconButton` is the one canonical tool icon (L318) | Mostly followed | One `InvisibleButton("##tool")` at `AssetLibrary.ToolsPopup.cs:148`. | T, - |
| Transparent background by default (L322) | Followed | `CustomComponents.Buttons.cs:158-207`. | T, - |
| `ButtonStates` semantics (L325-335) | Followed | `enum ButtonStates` at `CustomComponents.Buttons.cs:466`. | T, - |
| `IconButton(Icon, size, state)` over char literals (L246) | Followed (sample) | `CustomComponents.Buttons.cs:158,207`. | T, - |
| `Icon.X.DrawAtCursor()` (L249) | Unverifiable | | T, - |
| Prefer `IconButton` over `TransparentIconButton` (L338) | Partly followed | The alias still exists at `CustomComponents.Buttons.cs:112` and is called internally at `:59`. | T, - |
| Toolbars wrap in `PushToolbarIconBackground` (L340-344) | Followed but fragile | 21 hits in 13 files. It works through a static bool toggle (`CustomComponents.Buttons.cs:228-229`). | T (weak), - |
| Don't draw UTF-8 glyphs in place of icons (L346) | Partly followed | `Editor/Gui/Windows/OutputSetup/SetupParameterView.cs:129`. ([06](06-theming-and-widget-library.md)) | P, - |
| Atlas has a fixed glyph range (L351-353) | **Stale** | ([06](06-theming-and-widget-library.md), [08](08-frame-loop-fonts-and-dpi.md)) | P, - |
| Ask the user to add a missing `Icon` (L358) | Unverifiable (process) | | P, - |

Two clusters stand out. The Title Case and sentence-case rules are pure convention, enforced only by eyes, and they held in live code. The ellipsis and glyph rules are facts about the font atlas, and those facts moved while the prose stayed put.

### Performance (L29-40 and L365-369)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| No allocations in draw code: no LINQ, no closures, no `params` (L365) | **Not followed** in MagGraph interaction code | `GraphContextMenu.cs:57,117,133,215,333,411,602` use `ToList`/`Select`/`Any` with closures. They run in menu bodies only while the menu is open, so the practical cost is low. Draw code is clean. `params` appears once at `Editor/Gui/Help/ShippedContent.cs:14`. ([10](10-per-frame-performance.md)) | P, R |
| Reuse static buffers (L366) | Followed | `MagGraphCanvas.DrawNode.cs:1326 _inputIndicatorPoints`. | P, - |
| Pass hot data by `ref` (L367) | Partly followed | `MagItemMovement.cs:1263`, `MagItemMovement.Snapping.cs:73`. | P, - |
| Tooltips inside `if (isHovered)` (L368) | Followed (sample) | `DrawNode.cs:348-351,700-701,957`, `ConnectionHovering.cs:125-128`. | P, - |
| Single global time source for pulsing (L369) | Unverifiable | | P, - |
| No allocations or LINQ per frame (L32-35) | Partly followed | Worst site: `Editor/Gui/Windows/SymbolLib/SymbolLibrary.cs:553-555`. ([10](10-per-frame-performance.md)) | P, R |
| Don't speculatively micro-optimise (L39) | Unverifiable | | P, R? |

### State and undo (L41-56 and L371-373)

| Rule | Verdict | Evidence | Held by |
|------|---------|----------|---------|
| Undo rule: use `AddAndExecute` (L371-373) | **Stale** | Drag edits use `Add` because the value is already live (`Editor/Gui/Windows/ParameterWindow.cs:848-882`). ([01](01-edit-lifecycle-and-undo.md)) | P, - |
| Construct the command on drag start, push on complete (L373) | Followed | `ParameterWindow.cs:848-882`. ([01](01-edit-lifecycle-and-undo.md)) | P, - |
| Prefer Guids over long-lived references (L41-44) | **Not followed** in op UIs | `Editor/Gui/OpUis/UIs/SequenceAnimUi.cs:29`. ([04](04-retained-state.md)) | P, R |
| Do not store `Instance` refs in commands (L50) | Followed | ([01](01-edit-lifecycle-and-undo.md), [04](04-retained-state.md)) | P, R |
| Undo should no-op and log if the symbol is gone (L52) | **Not followed** | `Editor/UiModel/Commands/Graph/ChangeInputValueCommand.cs:41,101` throws. ([01](01-edit-lifecycle-and-undo.md)) | P, - |
| L56 names `MoveTimeClipsCommand` as holding `Instance` refs | **Stale, already fixed** | `Editor/UiModel/Commands/Animation/MoveTimeClipsCommand.cs:28,32,146-151`. ([01](01-edit-lifecycle-and-undo.md), [04](04-retained-state.md)) | P, - |

### Process rules: What Cannot Be Checked Against Code

Two rules are about behavior, not code: "Ask clarifying questions about behavior and visuals first" (L155) and "Ask the user to add a missing Icon" (L358). They are prose only, absent from the review, and cannot be checked against source. They belong in prose. Keep that in mind for the checklist later.

### What the Map Leaves Off Entirely

Chapter [05](05-id-stack-and-widget-identity.md) found that the document has no rule at all about ImGui ids, even though the code has 192 `PushID` sites and six families of push values. The review checklist has the opposite gap: it enforces things the guide never states: "native sliders instead of FormInputs", a naming vocabulary, serialization defaults and threading.

---

## What Separates Rules That Held From Rules That Drifted?

### Rules that hold

Four kinds of rule held up under sampling:

1. **Cheap pattern-matched rules.** Title Case in live code, tooltips inside `if (isHovered)`, reusing static buffers, and the single-draw-list approach in MagGraph. An author can see the right pattern in the neighboring file and copy it.
2. **Rules a helper makes the easy path (the signs).** `IconButton`, `ButtonStates`, `Color.Mix`, `UiColors`. Writing the right thing costs less than writing the wrong thing.
3. **Rules a type carries (the guardrails).** `ButtonStates` is an enum, so "which states exist" cannot drift from the code.
4. **Rules that match how the code was shaped.** Constructing a command on drag start and pushing it on completion held because the edit lifecycle has one choke point ([01](01-edit-lifecycle-and-undo.md)).

### Rules that drift

The rules that failed share a profile. Each depends on **unchecked global state** or **fights convenience**:

- "Multiply every literal by `UiScaleFactor`" fights the convenience of typing a bare number, and the factor itself is a mutable static.
- "Reset `Fonts.*.Scale`" depends on remembering to undo a global change on every exit path.
- "Never mutate `.A`" fights the fact that `.A` is a public field.
- "No LINQ" fights the fact that LINQ is the shortest way to write a menu filter.

Prose cannot compete with convenience. These are rules that live only on the paper map. The author in a hurry takes the short path, and no one is standing there to say no.

### Four tells of drift

When you audit your own conventions doc, look for these four signals:

1. **Stale facts in prose.** The document says `Fonts` is an enum when it is a static class, describes a fixed glyph range the atlas no longer has, and gives an undo rule that the code contradicts. Any sentence that states a fact about the code (rather than a judgment) will eventually be false.
2. **Guide-versus-code contradictions that nobody reconciled.** "Use three periods, not `…`" sits next to a UI string that uses `…` and an atlas built to draw it. Neither side is obviously wrong, so neither got fixed.
3. **Unmentioned exceptions.** `ColorEditPopup` mutates alpha because it is a color editor. Menu bodies allocate because they only run while open. Both are defensible, and neither appears in the document, so every reader has to rediscover the exception or assume a violation.
4. **Violations concentrated in newer files.** `WelcomeAlphaWindow` and `SetupParameterView` show up in the label and glyph rows. New files are written by people (or agents) who have not absorbed the surrounding habits, so they are where a rule's real enforcement strength shows.

---

## What Review Enforces and What It Does Not

`FEATURE_REVIEW.md` covers a narrow slice of the guide: the scale factor, new `Color` construction, native sliders, font scale reset, allocations and Instance/Guid lifetimes. That is a reasonable slice, because those are the rules with the highest cost when broken.

It does **not** cover:

- Title Case and ellipsis rules.
- Glyph use versus icons.
- Use of the tool-icon helper.
- Use of the context-menu helper.
- Pixel alignment.
- Undo.
- The meaning of status colors.

Undo is the most consequential omission. The rule is stale and the code already contradicts it: drag edits use `Add`, not `AddAndExecute`, and an undo command throws where the guide says it should log and skip. An agent that obeys the guide literally would "fix" correct code into incorrect code, and no reviewer checklist would catch it.

Notice also that the review checks some things the guide never states. Two documents that describe the same expectations should be one list. When they are separate, each drifts from the other as well as from the code.

---

## Rust Translation: Turning Paragraphs into Guardrails with Types, RAII, Lints and Tests

C# can carry some of this too, but Rust is unusually good at it. The compiler already rejects whole categories of mistake, and the ecosystem has tools for the rest. For every prose-only rule in the audit, ask: can this move into a guardrail? The recommendations below map the failures to Rust encodings. They are design suggestions for a new framework, not behavior we observed in tixl.

### RAII guards for font, style and scale

The `Fonts.FontSmall.Scale = 1; // WTF` comment exists because a global change had no scope. In dear-imgui-rs 0.8, `push_style_color`, `push_style_var`, `push_font` and `push_id` already return tokens that pop when dropped. If your own helpers (a scale override, a font size tweak) follow the same convention, a forgotten reset becomes impossible, including on early returns.

Here is the shape. This is a sketch of the idea, not an API from the crate.

```rust
// A scope guard: the override lives exactly as long as the token.
let _small = ui.with_font_scale(font, 0.8);
draw_node(ui, node);
// `_small` drops here, even if draw_node returned early.
```

The rule "reset the scale before returning" disappears from the document because the language enforces it.

### A logical-pixel newtype

"Every pixel literal multiplied by `UiScaleFactor`" is a rule about a unit. Rust handles units with types. Define `Px(f32)` for logical pixels and make your widget helpers accept `Px`, not `f32`. The conversion to physical pixels happens inside one function. An unscaled `4.0` no longer type-checks against the helper, so the tooltip padding at `ConnectionHovering.cs:127` could not have been written the same way. The "don't double-scale" rule disappears too, because a `Px` cannot be scaled twice by accident if the only scaling point is the boundary.

### A theme color token without a raw constructor

"Never construct `new Color(...)` in draw code" and "never mutate `.A`" are both about who may make colors. Make a `ThemeColor` type whose constructor is private to the theme module. Draw code receives tokens from the theme (`theme.status_error`) and can derive variants through methods like `mix` and `with_alpha`. Raw floats can only be turned into a color inside theme code. The color-editor exception then becomes visible: it must import an explicit raw-color type, so the exception is declared in code instead of discovered by accident.

### A command trait that stores ids and returns Result

Three undo rules failed or went stale: store ids not instances, no-op if the target is gone, and which push method to call. One trait can carry all three.

The next sketch shows a trait where commands hold only ids, resolve targets on every call, return `Result` so a missing target cannot panic, and expose a single stack entry point with an explicit "already applied" method.

```rust
trait Command {
    // Resolve ids against the live model on every call; never hold references.
    fn apply(&mut self, model: &mut Model) -> Result<(), CommandError>;
    fn revert(&mut self, model: &mut Model) -> Result<(), CommandError>;
}

impl UndoStack {
    // Normal path: apply now, then record.
    fn execute(&mut self, cmd: Box<dyn Command>, model: &mut Model) { /* ... */ }
    // Drag path: the value is already live, so only record.
    fn push_already_applied(&mut self, cmd: Box<dyn Command>) { /* ... */ }
}
```

The `Add` versus `AddAndExecute` confusion, which made tixl's written rule stale, becomes two well-named methods. "No-op and log if the symbol is gone" becomes an `Err` the stack handles in one place. A command cannot hold an `Instance` reference if it only has ids to store, and the borrow checker rejects a stored reference to model data anyway.

### Clippy lints that forbid raw APIs

The helper-versus-raw counts (199 against 37, 131 against 199) show a helper cannot win by existing. Clippy's `disallowed_methods` and `disallowed_types`, configured in `clippy.toml`, can ban the raw popup and menu calls everywhere except the helper module. A contributor who writes a raw `begin_popup_context_item` gets a lint error pointing at the helper. Allow the call in the helper module with a targeted `#[allow]`, so each exception is visible in the diff.

### Tests that scan labels

Title Case and `...` versus `…` are string rules, and strings are easy to test. A snapshot or unit test can collect the menu labels (a registry of command labels makes this natural) and assert Title Case with the preposition exceptions, assert no `…` character, and assert that submenu headers have no trailing ellipsis. Our audit did this by reading about 30 labels by eye. A test does it on every commit, including for the newer files where violations clustered.

### Generate stale-prone facts from code

The three stale rules (Fonts "enum", glyph range, font roles) were all statements of fact. Do not write those by hand. Generate the glyph range table and the font role list from the same source the renderer uses, and include the output in the docs build. The doc can never disagree with the code because it is the code's output.

### Keep prose for judgment

Prose still has a job. "Ask clarifying questions first", "don't speculatively micro-optimise" and "ask for a missing icon" are judgment and process rules. No type can carry them, and they were not wrong. A good rules document is short, and everything left in it is something only a person (or an agent) can decide.

### One list, not two

Merge the review checklist and the rules document. Each rule gets one entry that says how it is enforced: type, lint, test, or review. A rule marked "review" is a rule that depends on a person. If your list has more of those than you can check, shorten the list.

---

## A Checklist for a Conventions Doc That Doesn't Drift

Here is the audit boiled down to eleven checks. Use them when you write conventions for an ImGui editor, and especially when agents will read them.

1. **Label every rule with its enforcement.** Type, helper, lint, test, review or "judgment only". A rule with no enforcement is a wish.
2. **Cut stated facts, generate them.** If a sentence describes what the code *is* (an enum, a glyph range, a font list), generate it or delete it.
3. **Write the exceptions down.** If a color editor needs raw alpha, say so and name the file. An unmentioned exception reads as a violation.
4. **Replace "no exceptions" with an enforcement.** The strongest wording drew the most violations.
5. **Make the right thing the shortest thing.** Helpers must be easier to call than the raw API, and the raw API should fail a lint.
6. **Scope every global change.** If a rule says "remember to reset X", turn X into a guard.
7. **Cover the consequential rules in review.** Rank rules by what breaks when they fail (undo, lifetimes) and check those first.
8. **Test the newest files hardest.** Violations concentrate where habits have not spread. Run lints and label tests on new code from day one.
9. **Keep rules measurable.** "Avoid excessive" and "~70% Normal" cannot be checked. Give a threshold or drop the rule.
10. **Re-audit on a schedule.** Sample two to four sites per rule, as we did here. It takes an afternoon, and it finds the stale rules.
11. **Write for a literal reader.** An agent will do exactly what the sentence says. Read each rule as if you could not ask what it meant.

---

## Next Steps

This chapter closes the ImGui craft set. Where to go from here:

- The rules that failed most often are covered in depth in [06 Theming and Widget Library](06-theming-and-widget-library.md) (colors, fonts, atlas), [07 Popups, Menus and Drag and Drop](07-popups-menus-and-drag-drop.md) (helpers and closures), [08 Frame Loop, Fonts and DPI](08-frame-loop-fonts-and-dpi.md) (scale factor) and [10 Per-Frame Performance](10-per-frame-performance.md) (allocation).
- The most consequential gap, undo, is the subject of [01 Edit Lifecycle and Undo](01-edit-lifecycle-and-undo.md), with [04 Retained State](04-retained-state.md) for the id-versus-reference rule.
- The identity rule that has no prose at all is in [05 ID Stack and Widget Identity](05-id-stack-and-widget-identity.md).
- For the scale and zoom rules, see [03 The Zoomable Canvas](03-zoomable-canvas.md). For input rules, see [02 Input Routing and Focus](02-input-routing-and-focus.md). Window and layout conventions are in [09 Windows, Docking and Layouts](09-windows-docking-and-layouts.md).
- Return to the [index](00-index.md).

---

## References

- `.agentic/AGENT_INSTRUCTIONS.md` (Realtime Performance L29-40, State and Resource L41-56, UI Implementation Guidelines about L150-375)
- `.agentic/Reviews/FEATURE_REVIEW.md`
- Source paths are cited inline, relative to `visual-programming/tixl/`, at the commit recorded in [SUBMODULE-PINS.md](../../../../SUBMODULE-PINS.md).
