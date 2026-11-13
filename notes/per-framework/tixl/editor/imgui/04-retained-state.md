# Chapter 04: Retained State Beside Immediate-Mode Drawing

> *ImGui forgets everything between frames. The editor cannot afford to, so it keeps a second memory elsewhere, and that memory goes stale in ways the draw loop never notices.*

---

## The Problem: A Framework That Forgets, an Editor That Must Remember

Immediate-mode drawing is a promise: you describe the whole UI every frame, and ImGui paints it. Nothing in the UI survives unless you re-declare it. That is why the style is so pleasant to write. There is no widget tree to keep in sync with your data.

But an editor is full of things that must outlive a frame. The user selected three nodes and expects them to stay selected. Each open project has its own pan and zoom. A drag that began 40 frames ago is still in progress. A view is gliding toward a new framing over a third of a second. A layout was computed once and should not be recomputed until something changes. None of this fits in "describe the UI each frame", so all of it lives somewhere else.

This chapter is about that somewhere else in tixl: what lives outside ImGui, who owns it, how it is reconciled with the frame, and how it goes stale. The last question is the interesting one. Retained state is a cache of intentions, and the world it refers to (instances, symbols, compiled operator types) can change underneath it. Most of tixl's hard-won comments are about exactly that.

The mental model: think of ImGui as a **whiteboard that gets wiped every frame**, and the retained state as the **notebook on the desk beside it**. Each frame you glance at the notebook, redraw the whiteboard from it, and occasionally write something new in the notebook. The notebook is the source of truth for UI intent. The whiteboard is only ever a rendering of it. Problems appear when the notebook mentions something (say, "node #7 of the operator I had open") that has since been torn down and rebuilt. A notebook entry cannot know that its subject has changed.

Our target editor has a clear stance that sharpens this: authored state lives in source documents, and derived views refresh after each command. So we care about three kinds of retained state, in decreasing order of how much they should worry us: UI intent (selection, navigation), in-flight interactions (drags, edits), and derived caches (layout). This chapter maps tixl's choices onto those three and then translates them into Rust. Command execution and undo are covered in [01-edit-lifecycle-and-undo.md](./01-edit-lifecycle-and-undo.md), so here we only touch commands where they intersect with retained state.

---

## The Inventory: What Lives Outside ImGui

Before the details, here is the whole notebook at a glance. Every row is state that ImGui will never hold for you.

| Kind | tixl example | Owner | Lifetime |
|------|--------------|-------|----------|
| Selection | `NodeSelection` | One per `ProjectView` | Cleared on composition change |
| Per-view navigation | `NavigationHistory`, canvas rect, `_compositionPath` | `ProjectView` | Project open to close |
| Persisted view layout | `UserSettings.Config.ViewedCanvasAreaForSymbolChildId` | Global settings | Across sessions |
| In-flight interaction | `StateMachine<GraphUiContext>` | `GraphUiContext` | Until state returns to `Default` |
| In-flight edit | `_inputValueCommandInFlight` | Static in `ParameterWindow` | Press to release |
| Animation | `EasedValue` | Owning view's field | Until settled |
| Derived cache | `MagGraphLayout` | The graph view | Until flagged changed |
| Window chrome | `Window.WindowConfig`, focus retry counters | Each `Window` | Layout-file or frame-scale |

Two facts stand out. First, most of this is owned by a **per-project view object**, and that is a good decision. Second, the rows that are static (the in-flight edit, plus a few arbiters we will meet) are where almost every bug in the Gotchas section comes from.

---

## The Core Trick: Store Names, Resolve Per Frame

Start with the most important piece, selection, because its design is the cleanest answer to "how do I refer to something that might not exist next frame".

`NodeSelection` (`Editor/UiModel/Selection/NodeSelection.cs`) opens with a class comment at lines 17-18 that states the rule plainly: "We can't store references to instances because this leads to null-references and reference leaks. For this reason we save id-paths: Basically the nesting path of instances from the dashboard operator down."

An **id-path** is a list of Guids: the child's id, preceded by the id of each operator you had to descend through to reach it. It is like a postal address instead of a person. If the person moves house, the address still parses, the lookup just comes back empty. A direct reference is like holding the person's arm: when they are removed from the building you are left holding something dead.

The class stores a few things:

- `List<ISelectableCanvasObject> Selection` (line 337), the selected items.
- `Dictionary<SymbolUi.Child, IReadOnlyList<Guid>> _childUiInstanceIdPaths` (339), the address for each.
- `_selectedCompositionPath` (338), set when the user clicks the background (45-53), meaning "the composition itself is selected".
- `PinnedIds` (32), ids that stay visible.
- `ChangeCounter` (341), bumped on every mutation. We will use it shortly.

Nothing is resolved ahead of time. When something needs the live instance, it calls `_structure.GetInstanceFromIdPath(idPath)` at the moment of use (lines 132, 138, 149, 164, 209). Nothing is cached across frames. The resolution cost is paid per use, in exchange for never holding a dead pointer.

### Stale handling is lazy, and only half-finished

Resolution can fail, and what happens then is worth being honest about. A failed lookup returns null or logs. The code that would clear invalid or obsolete selection is commented out (128-130, 144-146). And `GetSelectedInstances` does `GetInstanceFromIdPath(idPath)!` (164), which means it can hand callers a null despite the non-null assertion. `GetSelectableChildren` wraps its work in try/catch with the comment "might be caused by recompilation" (240-243).

So the design is "resolve on demand, tolerate failure", with the pruning step missing. Selection mostly stays correct because of explicit invalidation points rather than because of continuous reconciliation:

- `ProjectView.OnRootDisposed` clears selection (`Editor/UiModel/ProjectHandling/ProjectView.cs:58-65`).
- `TrySetCompositionOp` clears it on every composition change (`ProjectView.cs:286`).
- Delete clears it after the macro completes (`Editor/UiModel/Modification/NodeActions.cs:133-135`), and `ChangeSymbol.cs:32` does the same.

Think of it as a notebook with a few well-placed "tear out this page" rules, but no proofreader. It works because the cases are enumerable. It breaks when a new way of invalidating the world appears that nobody added a clear call for.

---

## Who Owns the Notebook: The Per-Project View Bundle

Selection does not float free. `ProjectView.cs` owns a bundle: `NavigationHistory`, `NodeSelection`, `GraphImageBackground`, `NodeNavigation` and `TimeLineCanvas` (lines 20-23, 176), plus `OpenedProject`, `GraphView`, and `_compositionPath` as a `List<Guid>` (28). One bundle per open project means two projects never share a selection.

Construction order is deliberate. `CreateIndependentComponents` builds history, selection and background first and passes them into the constructor (217-224, 202). The pieces that do not depend on a live instance exist before the thing that does.

### The one deliberate instance reference

The view also holds `InstanceView? _instView`, the live composition instance (30-32). This is the single place the architecture knowingly keeps an instance, because the view is literally a window onto it. The price is a disposal protocol: old instances go on a `_compositionsAwaitingDisposal` stack (69, 107-127) and are released later, not in the middle of a frame that may still be drawing them. That deferral is itself a retained-state pattern: "do not tear down the thing the whiteboard is currently using".

There is also a small smell the authors flagged themselves: the composition path is held twice (278-279, marked TODO).

### Persistence of the notebook

Some view state outlives the session. On composition switch the canvas rect is saved into `UserSettings.Config.ViewedCanvasAreaForSymbolChildId[Guid]` (`ProjectView.cs:236`; the dictionary is declared at `UserSettings.cs:76`). Window layout and visibility are saved into the root SymbolUi, and the new value is compared against the old first so no-op saves are skipped (420-449). Note the key: a Guid, again. The address is stable across sessions, where a pointer would not be.

---

## Reconciling With the Frame: Pull, Diff, Flag

If the state is outside ImGui, something has to notice when it changed. tixl uses three different mechanisms, and they are worth contrasting.

### 1. Pull and diff (selection to parameter window)

The Parameter window needs to know when selection changed in some other window. There is no event. Each frame it polls `NodeSelection.TryGetSelectedInstanceOrInput` (`Editor/Gui/Windows/ParameterWindow.cs:75`). That reads `ProjectView.Focused.NodeSelection` (`NodeSelection.cs:296-303`) and compares an id against a static `_lastSelectionId`, guarded by `_lastFrameCount` so the comparison happens once per frame (323-329, 343-344).

This is the cheapest possible cross-window sync: the consumer remembers what it last saw. It is also where the statics bite, as the Gotchas below show.

### 2. Event broadcast (composition content)

`ProjectView.FlagChanges(ChangeTypes)` raises `OnCompositionContentChanged` (181-197), flagging Connections, Children, Layout, Composition or GraphStyle. `MagGraphView` subscribes (`Editor/Gui/MagGraph/Ui/MagGraphView.cs:42-43`) and unsubscribes in `Close` (195-196). The unsubscribe is not decoration: a leaked handler would keep a dead view alive.

### 3. Manual dirty flag (layout cache)

The layout cache is the third pattern, and it has the most instructive trade-off. We trace it next.

---

## Trace: Moving a Node and Refreshing the Layout

Let's trace what happens when the user drags a node and the graph layout must refresh. The model side is covered in [../maggraph/05-model-layout.md](../maggraph/05-model-layout.md); here we only follow the cache invalidation.

1. Every frame, `MagGraphCanvas.Drawing.cs:74` calls `ComputeLayout`.
2. `ComputeLayout` (`Editor/Gui/MagGraph/Model/MagGraphLayout.cs:57-79`) is cheap by default. It only calls `RefreshDataStructure` if one of four conditions holds: `forceUpdate`, `FrameStats.Last.UndoRedoTriggered`, `StructureFlaggedAsChanged`, or `HasCompositionDataChanged(...)`.
3. While the user drags, the interaction code changes positions through commands. Those call `FlagStructureAsChanged()` (line 81).
4. The first flag also calls `parentSymbolUi.BumpVersionCounter()` without marking the document modified (64-70). That is a version bump for observers, deliberately not a "you have unsaved changes" signal.
5. Next frame, step 2 sees `StructureFlaggedAsChanged` and rebuilds the layout once.
6. Frames after that skip the rebuild until something flags again.

Now the uncomfortable part. `HasCompositionDataChanged` hashes only `composition.Id` (1203-1212). It detects switching to a different composition, nothing more. The comment at 1199-1202 explains why: "We rely on manually flagging structure changes, because computing a hash of a composition is not easy because the item order of children can change."

So correctness depends on every mutation site remembering to call `FlagStructureAsChanged()`. There are about 40 such call sites, plus event handlers (`MagGraphView.cs:49-61`). Miss one and the graph silently shows an old layout. That is the cost of a cache without a trustworthy version signal.

A related distinction trips readers up: `DirtyFlag` (`Core/Operator/Slots/DirtyFlag.cs`) is about evaluation invalidation in the operator graph, not UI caching. The editor even reaches across to force it: `NodeSelection.cs:354-364` calls ForceInvalidate every frame on the selected transformable's Vector3 inputs, skipping strings. Two different "dirty" notions coexist, and neither is the layout's.

---

## In-Flight Interactions: A State Machine Beside the Frame

A drag has a beginning, a middle and an end, and the middle spans many frames. ImGui cannot hold that, so tixl keeps it in a small state machine. The deeper treatment lives in [../maggraph/07-state-machine.md](../maggraph/07-state-machine.md) and the data it carries in [../maggraph/08-context.md](../maggraph/08-context.md). Here is only the part that matters for retained state.

`Editor/Gui/UiHelpers/StateMachine.cs` defines `State<T>` as a record struct of three optional callbacks, `Enter`, `Update` and `Exit` (7-9). `StateMachine<T>` holds `_currentState`, a `_stateEnterTime` stamped from `ImGui.GetTime()`, and the class type that declares the states (64-67). `SetState` runs Exit on the old state, swaps, stamps the time, then runs Enter on the new one (30-39). `UpdateAfterDraw` runs Update (25-28).

The key design choice is that **states are stateless**. They are static values, for example `internal static State<GraphUiContext> X = new(Enter: ctx => ..., Update: ...)` (`Editor/Gui/MagGraph/States/GraphStates.cs:19-21`). All data lives in `GraphUiContext`, and `Default.Enter` resets it (24-34). Think of a flight checklist: the checklist (state) says what to do, while the plane's actual altitude and heading (context) live in the cockpit. In notebook terms, the checklist is a printed page and the context is the page you scribble on.

Two details are worth noting. State names for debugging come from reflecting over the static fields using record-struct equality (44-61), and that is only used by `ToString`, so it is not on the hot path. And "is the user mid-interaction?" is a one-liner: `MagGraphView.HasActiveInteraction` is `CurrentState != GraphStates.Default` (`MagGraphView.cs:184`). The same machine is reused by skill training (`Editor/Skills/Training/SkillTraining.cs:560`). `GraphUiContext.cs:75` has a comment that the machine "needs to be initialized last", because its enter callbacks read the rest of the context.

---

## Animation: Eased Values Advanced by the Caller

Animation is retained state too: a view's current framing is a function of where it started, where it is going and how long ago it left. `Editor/Gui/UiHelpers/EasedValue.cs` captures this in a plain struct with `Target`, `From`, `Progress` ("0 at the start of a transition, 1 once settled") and `Value` (8-16).

Usage is intentionally boring. The owning view stores it as a field (for example `SetupOutputView.cs:920,926`, `SetupOutputView.Framing.cs:237`, `SetupOutputView.Photo.cs:487,495`), initialized with `EasedValue.Settled(x)` (20). `Retarget(target)` does nothing if the target is unchanged (26-35), which makes it safe to call every frame from immediate-mode code. `Advance(dt, duration, exponent)` returns early once settled (53-61). The caller advances it once per frame: `_viewMorph.Advance(FrameDeltaSec(), ...)` (`SetupOutputView.cs:156`).

There are no timers, no registry and no allocation. Time comes from the caller's delta. That is the right shape for immediate mode: the struct is a value, the frame loop is the clock.

---

## Does the Code Follow Its Own Rule?

The repository's agent-facing rules document makes a clear statement about the notebook: write down names, not references. You might wonder whether the code actually follows it, so here is the rule, then where it holds and where it does not.

> **Stated rule vs. code**
>
> **Rule** (`.agentic/AGENT_INSTRUCTIONS.md:41-44`): avoid storing long-lived direct references; prefer storing and resolving by Guid; be careful with stale references across reloads. Lines 46-56 extend it to commands: no Instance, Symbol or SymbolUi fields; re-resolve in each Do/Undo; no-op and log if the target is gone.
>
> **Applied**
> - `ParameterWindow.cs:121-131` copies symbol, parent symbol and path, then nulls the instance ("allow to unload of instance type in case a recompilation occurs") and re-fetches with `symbol.TryGetOrCreateInstance(path, ...)`.
> - `ProjectView.TrySetCompositionOpToChild` builds `[.._compositionPath, symbolChildId]` and resolves it (327-332).
> - `NodeSelection` stores id-paths and resolves on demand.
>
> **Violated**
> - Per-op custom UIs hold `private readonly Instance _instance;` (`Editor/Gui/OpUis/UIs/SequenceAnimUi.cs:29`, `AnimValueUi.cs:25`, and about 12 others).
> - `MagGraphView._previousInstance` (`MagGraphView.cs:167`) is compared by identity, `CompositionInstance != _previousInstance` (172), and a mismatch rebuilds the whole `GraphUiContext` (180). A TODO at 171 wants the check moved into a handler.
> - Static instance fields: `ParameterPopUp.cs:274 _selectedInstance`, `TransformGizmoHandling.cs:1302 _instance`, `LibWarningDialog.cs:55 HandledInstance`.
> - Selection is keyed on `SymbolUi.Child` object references (`NodeSelection.cs:339`), so the "id-path" strategy sits next to a reference key.
>
> **The rules doc lags the code.** Line 56 still says "Some older commands (MoveTimeClipsCommand) still hold Instance references; treat those as latent bugs". But `Editor/UiModel/Commands/Animation/MoveTimeClipsCommand.cs` already stores `Guid[] _compositionPath` (28, 32) and re-resolves through `ProjectView.Focused?.Structure.GetInstanceFromIdPath(_compositionPath)` (146-151). The bug the document warns about has been fixed. Trust the code, and when you copy a rule, re-verify its examples.

The violations cluster in per-op UIs and dialogs, where a developer wants a convenient handle for the current frame. The rule holds best where structure enforces it (commands, selection) and erodes where it relies on discipline.

---

## Gotchas: Where the Notebook Goes Stale

Each item below is a place where retained state can outlive, or disagree with, the thing it describes. Items marked **unverified** are open questions, not confirmed bugs.

**Recompilation turns instance refs into null refs.** Two comments say it outright (`NodeSelection.cs:242`, `ParameterWindow.cs:126`). tixl hot-reloads operator code, so any instance held across a reload points at a dead type. This is the root cause behind the try/catch and the "unload the instance" trick above.

**Static field initializers do not re-run on hot reload.** `Editor/Gui/MagGraph/Interaction/GraphContextMenu.cs:34` notes that a static initializer collapses to 0 after a reload. A static holding a counter or a default is not a safe place for state in a reloadable editor.

**Clipboard staleness.** `KeyboardActions.cs:31` warns that clipboard contents can refer to things that no longer exist when pasted.

**Static in-flight commands.** `ParameterWindow.cs:1017-1018` has `static ChangeInputValueCommand? _inputValueCommandInFlight` and `static IInputSlot? _inputSlotForActiveCommand`. The lifecycle: created on edit start (855-866), `AssignNewValue` while dragging (869), pushed on release (875-877), nulled (880). Being static, it also holds an `IInputSlot` reference. Whether the project closing mid-drag leaves this dangling is **unverified**; nothing in the trace shows cleanup.

**Statics that leak between views.** The set to watch: `ProjectView.Focused`, `_lastSelectionId`, `_lastFrameCount`, `GlobalSelectionHandling.SetupEntities`, and the in-flight command above.

**`ProjectView.Focused` is a hidden parameter.** It is `public static ProjectView? Focused { get; private set; }` (`ProjectView.cs:517`), set in `SetAsFocused` (401-408) and nulled in `Close` (398), but only if the closing view is the focused one (371-372). It has about 169 uses across 69 Editor files. Anything that reads it silently depends on "which window did the user touch last", including during frames where a different view is being drawn. The risk is real; whether specific call sites misbehave with two projects open is **unverified**.

**A global arbiter with one owner.** `GlobalSelectionHandling` (`Editor/UiModel/Selection/GlobalSelectionHandling.cs:30-54`) is a static arbiter with a single owner (GraphNode or SetupEntity). Claiming selection clears the other; Release only works for the current owner. It is a clean idea, and also a second piece of global retained state.

**Selection scaling.** `NodeSelection.cs:336` comments that the List with O(n) Contains would need a dictionary above about 500 items.

**Unique ImGui labels from a counter.** `UIControlledSetting` generates ids from a static `ushort` counter (`UIControlledSetting.cs:25,48-49`). Fine until it wraps or the process reloads (the wrap behavior is **unverified**; this is an inference from the type).

**Settings keyed by free-form strings.** `UserSettings.Config` is global (`UserSettings.cs:76-78, 300-305`) holding `Dictionary<Guid, ImRect>` view areas, and `LastOpsForWindows` keyed by window title. A window rename orphans its entry.

**ImGui id stack drift.** `Window.cs:141-147` adds a cheap self-check around content drawing, which catches a push without a pop:

```csharp
var idBefore = ImGui.GetID(0);
DrawContent();
var idAfter = ImGui.GetID(0);
if (idBefore != idAfter)
    Log.Warning($"Inconsistent ImGui-ID after rendering {this}  {idBefore} != {idAfter}");
```

The block above is the whole mechanism. It is retained-state hygiene in the sense that a leaked id push corrupts every widget state ImGui keeps internally (open tree nodes, scroll positions), all keyed by id. It is worth copying.

**Window chrome has its own transients.** `Window.WindowConfig { Title, Visible }` is serialized by field name (`Window.cs:254-261`) and applied by `Editor/Gui/Windows/Layouts/LayoutHandling.cs:185-200, 207-210`. Alongside it sit transient fields: `_wasVisible`, `_focusRequestFramesLeft` (a 20-frame retry, `Window.cs:58-61`) and `_wasDockedLastFrame`. Window instances are copied into a reused `_instancesToDraw` list before drawing (227-244), presumably so the window set can change while the loop runs (the intent is our inference). The 20-frame retry is a nice admission that focus requests in ImGui are "try until it sticks".

---

## Rust / dear-imgui-rs Translation

The target editor keeps authored state in source documents and refreshes derived views after each command. That already removes the most dangerous category (authored data held in UI objects). What remains is selection, navigation, interactions, animation and caches. Here is how to carry tixl's lessons across, and where Rust lets us do better than a convention.

### Selection: ids plus a composition path, resolved per frame

Keep selection as plain ids and a path from the root. Resolve each frame, returning `Option`, and prune what fails. tixl left pruning commented out; in Rust the type system makes the missing case impossible to ignore. The sketch below shows a selection that never holds references and bumps a counter on mutation.

```rust
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(pub u128);

#[derive(Default)]
pub struct Selection {
    path: Vec<NodeId>,        // composition path from the root
    selected: Vec<NodeId>,    // ids only, never references
    version: u64,             // bumped on every mutation
}

impl Selection {
    pub fn set(&mut self, ids: Vec<NodeId>) {
        self.selected = ids;
        self.version += 1;
    }

    /// Resolve against the current document. Prunes ids that no longer exist,
    /// so stale selection cleans itself instead of yielding dead handles.
    pub fn resolve<'d>(&mut self, doc: &'d Document) -> Vec<&'d Node> {
        let Some(comp) = doc.composition_at(&self.path) else {
            self.selected.clear(); // composition gone: drop everything
            self.version += 1;
            return Vec::new();
        };
        let before = self.selected.len();
        self.selected.retain(|id| comp.node(*id).is_some());
        if self.selected.len() != before {
            self.version += 1;
        }
        self.selected.iter().filter_map(|id| comp.node(*id)).collect()
    }
}
```

Two properties matter. The returned references borrow from the document for one frame only, so the borrow checker enforces "nothing cached across frames" (tixl's convention, now a compile error to break). And pruning is part of resolution, so there is no separate proofreader to forget to call.

### A per-view bundle, passed explicitly

Replace the static `Focused` with a bundle handed down the call tree. This is what tixl's `ProjectView` already is, minus the global pointer. The sketch shows the bundle and the draw entry point that takes it.

```rust
pub struct ViewState {
    pub selection: Selection,
    pub nav: NavigationHistory,
    pub canvas: CanvasView,        // pan/zoom
    pub interaction: Interaction,  // state machine, see below
    pub layout_cache: LayoutCache,
}

pub fn draw_graph(ui: &Ui, view: &mut ViewState, doc: &Document) { /* ... */ }
pub fn draw_parameters(ui: &Ui, view: &ViewState, doc: &Document) { /* ... */ }
```

Which view is "focused" becomes a value the app shell picks once per frame and passes in. Two projects, or two views of one project, then cannot cross-contaminate, and tests can create a view without touching global state.

### Pull-based cross-window diffs with a version counter

tixl's `_lastSelectionId` plus `_lastFrameCount` is a hand-rolled version of a simpler idea. Each consumer stores the last `version` it saw. No statics, no per-frame guard, and it works for any number of consumers. The sketch shows a parameters panel as one such consumer.

```rust
pub struct ParametersPanel {
    seen_selection: u64,
    cached: Option<ParamModel>,
}

impl ParametersPanel {
    pub fn draw(&mut self, ui: &Ui, view: &mut ViewState, doc: &Document) {
        if self.seen_selection != view.selection.version() || self.cached.is_none() {
            self.cached = ParamModel::build(view.selection.resolve(doc));
            self.seen_selection = view.selection.version();
        }
        // draw self.cached ...
    }
}
```

The panel owns its own bookkeeping. If it is closed for ten frames and reopened, it compares one integer and catches up.

### One ChangeTypes event from the command executor

tixl's roughly 40 `FlagStructureAsChanged()` sites are the biggest correctness risk in the trace: the cache is only right if every mutator remembers. In an editor where all edits go through a command executor (see [01-edit-lifecycle-and-undo.md](./01-edit-lifecycle-and-undo.md)), the executor is the single choke point. Let commands declare what they touch, and have the executor emit one event after Do, Undo and Redo.

```rust
bitflags::bitflags! {
    #[derive(Clone, Copy, PartialEq, Eq)]
    pub struct ChangeTypes: u32 {
        const CONNECTIONS = 1 << 0;
        const CHILDREN    = 1 << 1;
        const LAYOUT      = 1 << 2;
        const COMPOSITION = 1 << 3;
        const STYLE       = 1 << 4;
    }
}

pub trait Command {
    fn apply(&mut self, doc: &mut Document);
    fn changes(&self) -> ChangeTypes;   // declared once, next to the code that mutates
}

impl Executor {
    pub fn run(&mut self, cmd: &mut dyn Command, doc: &mut Document) -> ChangeTypes {
        cmd.apply(doc);
        let flags = cmd.changes();
        doc.bump_version(flags); // views diff this next frame
        flags
    }
}
```

The flag now lives beside the mutation it describes, and undo/redo get it for free (tixl needs the separate `UndoRedoTriggered` check at `MagGraphLayout.cs:57-79` for that). A layout cache refreshes when `doc.version` differs from the version it was built at. That is the same pull-and-diff as selection, with one mechanism for the whole editor.

### EasedValue as a Copy struct advanced with frame dt

tixl's design translates almost verbatim, and Rust makes the "no allocation" property structural. Read `dt` from `ui.io().delta_time()` once and pass it down.

```rust
#[derive(Clone, Copy)]
pub struct Eased { from: f32, target: f32, progress: f32 }

impl Eased {
    pub fn settled(x: f32) -> Self { Self { from: x, target: x, progress: 1.0 } }
    pub fn retarget(&mut self, t: f32) {
        if t != self.target { self.from = self.value(); self.target = t; self.progress = 0.0; }
    }
    pub fn advance(&mut self, dt: f32, duration: f32) {
        if self.progress >= 1.0 { return; }
        self.progress = (self.progress + dt / duration).min(1.0);
    }
    pub fn value(&self) -> f32 {
        let t = 1.0 - (1.0 - self.progress).powi(3); // ease-out
        self.from + (self.target - self.from) * t
    }
}
```

Starting a new transition from the current `value()` rather than from the old target avoids a visible jump when retargeting mid-flight. (The trace does not show how tixl's `Retarget` picks `From`; this sketch is our design, not a restatement.)

### State machine as enum plus match, with a context struct

tixl's static `State<T>` values with callbacks exist to emulate what an enum does natively. Model each state as a variant carrying only what is specific to that state, keep shared data in a context, and make transitions explicit return values. The deep dive is in [../maggraph/07-state-machine.md](../maggraph/07-state-machine.md); context design is in [../maggraph/08-context.md](../maggraph/08-context.md).

```rust
pub enum Interaction {
    Idle,
    DragNodes { started_at: f64, grab: Vec2 },
    Connecting { from: PortId },
}

impl Interaction {
    pub fn update(&mut self, cx: &mut GraphContext, ui: &Ui) {
        let next = match self {
            Interaction::Idle => cx.try_begin(ui),
            Interaction::DragNodes { grab, .. } => cx.drag(ui, *grab),
            Interaction::Connecting { from } => cx.connect(ui, *from),
        };
        if let Some(next) = next { *self = next; }
    }
    pub fn is_active(&self) -> bool { !matches!(self, Interaction::Idle) }
}
```

Enter and Exit logic becomes the code that constructs and consumes a variant, and "reset the context on Default.Enter" becomes dropping the variant. The compiler checks that every state is handled, which tixl's reflection-based naming and "initialize last" caveat paper over.

### No static in-flight commands

The parameter window's static in-flight command should be a field on the panel (or inside the `Interaction` enum if it is a canvas gesture). In-flight edits should hold ids and a prior value, not an `IInputSlot`-style handle, and should be dropped when the view is. If the project closes mid-drag, the owner goes away and so does the draft. That removes the unverified leak above by construction.

### No instance references in UI structs

tixl's per-op UIs hold `Instance` because it is convenient. In the Rust editor, runtime objects (compiled operators, GPU resources) belong to the engine side, and UI structs hold ids and borrow what they need inside the draw call. A `&'a Instance` field in a struct stored across frames will not compile when the owner can be rebuilt, which is precisely the point. When a panel genuinely needs a cache of derived data, store the data (plus the version it was derived from), not the object.

### Smaller translations

- Persist view state keyed by stable ids, as tixl does with Guids, not by window title.
- Collect `Window` visibility in a serializable config struct and keep focus retries and "was docked" flags in a separate transient struct that is never saved.
- Copy the ID-stack check from `Window.cs:141-147` into debug builds of the panel runner.
- Make the layout cache hold `built_at_version: u64`, replacing the hash-or-flag dilemma.

---

## Summary

| Concern | tixl today | Rust editor |
|---------|-----------|-------------|
| Selection | id-paths, resolved lazily, prune commented out | ids + path, resolve returns `Option`, prunes |
| Which view | static `ProjectView.Focused` | `&mut ViewState` passed explicitly |
| Cross-window sync | static `_lastSelectionId` | per-consumer `seen_version` |
| Layout cache | ~40 manual flag calls | executor emits `ChangeTypes` |
| Animation | `EasedValue` struct + caller dt | `Copy` struct + frame dt |
| Interactions | static states + context | enum + match + context |
| In-flight edit | static command | field owned by the view |
| Instance refs | allowed in per-op UIs | not in UI structs |

The pattern to keep in mind is the notebook and whiteboard. Anything on the whiteboard is disposable. Anything in the notebook must be written in a form that survives the world changing: names, not pointers; versions, not guesses; owners, not statics.

---

## Next Steps

- [01-edit-lifecycle-and-undo.md](./01-edit-lifecycle-and-undo.md) covers where commands are created, executed and undone, which is the choke point the `ChangeTypes` event hangs off.
- [../maggraph/05-model-layout.md](../maggraph/05-model-layout.md) shows what the layout cache contains.
- [../maggraph/07-state-machine.md](../maggraph/07-state-machine.md) and [../maggraph/08-context.md](../maggraph/08-context.md) go deeper on the interaction machine and its context.

## References

All paths relative to `visual-programming/tixl/`.

- `Editor/UiModel/Selection/NodeSelection.cs`, `Editor/UiModel/Selection/GlobalSelectionHandling.cs`
- `Editor/UiModel/ProjectHandling/ProjectView.cs`
- `Editor/Gui/MagGraph/Model/MagGraphLayout.cs`, `Editor/Gui/MagGraph/Ui/MagGraphView.cs`
- `Editor/Gui/UiHelpers/EasedValue.cs`, `Editor/Gui/UiHelpers/StateMachine.cs`
- `Editor/Gui/MagGraph/States/GraphStates.cs`
- `Editor/Gui/Windows/ParameterWindow.cs`, `Editor/Gui/Windows/Window.cs`
- `Editor/UiModel/Commands/Animation/MoveTimeClipsCommand.cs`
- `.agentic/AGENT_INSTRUCTIONS.md`
