# Chapter 01: Edit Lifecycle and Undo

> *An immediate-mode widget rewrites your value sixty times a second, yet the user pressed undo once. Who decides where one gesture ends?*

Paths in this chapter are relative to `visual-programming/tixl/` and are cited as `Editor/...:line`.

---

## The Problem: Sixty Mutations, One Undo Entry

Immediate-mode UI has a famously simple contract: every frame you call `slider(&mut value)`, and if the user is dragging, the widget writes a new number into `value`. There is no "on change" event, no begin/end callback, no object that remembers what the widget looked like a moment ago. The widget just mutates your data and returns.

That is wonderful for drawing and terrible for undo. A user drags a float from 0.2 to 0.9 over a second. The widget mutates the value roughly sixty times. If you record every mutation, one Ctrl+Z moves the value from 0.9 to 0.8985 and the user concludes your editor is broken. What they want is the whole drag to be one step: 0.9 back to 0.2.

The problem gets harder when a gesture touches many things. Dragging a selection of twelve nodes moves twelve positions per frame, and may also snap a node onto a connection or split it, which are structural edits. The user still expects one undo to put everything back.

So the editor needs something that sits between the widgets and the undo stack and answers two questions every frame: has a gesture started, and has it finished? This chapter follows how tixl answers them, what is clumsy about its answer, and what a Rust editor on dear-imgui-rs should copy and change.

## The Mental Model: A Tape Recorder With a Punch-In Button

Think of a recording studio. The musician plays continuously, and the sound goes straight to the speakers (that is the live value changing on screen). The engineer does not store every sound wave as a separate "take". They press record when the musician starts, and stop when the musician stops. One take is one entry on the shelf, and the shelf can be played backwards one take at a time.

In tixl:

- The widget is the musician. It plays live and mutates the model directly.
- The edit-state flags are the cues ("starting", "playing", "done").
- `ParameterWindow.HandleInputEditState` is the engineer. It starts a recording on the first cue and shelves it on the last.
- The command object is the tape. It captured what the model sounded like before the musician started, so it can rewind.
- `UndoRedoStack` is the shelf.

The key insight is that the model is already changed when the command reaches the stack. The command is a receipt for a change that has happened, not an instruction to make one. (Read "tape" and "receipt" as the same object: a record of something that already played.) Everything odd about this design, such as `Add` versus `AddAndExecute`, follows from that.

---

## The Edit-State Contract: Telling the Editor What the Widget Just Did

Every parameter widget in tixl returns a flags enum describing what happened this frame (`Editor/UiModel/InputsAndTypes/IInputUi.cs:9-19`, used as the return type of `IInputUi.DrawParameterEdit` at `IInputUi.cs:47`). It is the entire vocabulary between widgets and the undo machinery:

| Flag | Value | Meaning |
|------|-------|---------|
| `Nothing` | 0 | No interaction this frame |
| `Started` | 1 | An edit has begun |
| `Modified` | 2 | The value changed this frame |
| `Finished` | 4 | The gesture is over |
| `ShowOptions` | 8 | The context menu asked for options (`InputValueUi.cs:605`) |
| `ResetToDefault` | 0x10 | The user asked for the default value |
| `ModifiedAndFinished` | `Modified \| Finished` | One-shot change, such as a button click |

Because it is a `[Flags]` enum, composite widgets simply OR their children together. `VectorValueEdit.cs:20,69` combines the per-component flags of a vector, and its +/- buttons return `ModifiedAndFinished` directly (53, 62), since a button click has no duration.

### Why the number widget is not an ImGui slider

You might assume tixl wraps `ImGui.DragFloat` and reads `IsItemDeactivatedAfterEdit`. It does not. `Editor/Gui/Interaction/SingleValueEdit.cs` is a custom state machine built from a plain `ImGui.Button` plus overlays. Of the three stock ImGui lifecycle queries only `IsItemActivated` is used for the main interaction (line 231). `IsItemActive` and `IsItemDeactivated` appear only for exiting text input or the dial (132, 175, 177). `IsItemDeactivatedAfterEdit` is never called.

Why build it by hand? The state machine supports jog dial, infinity slider, slider ladder and radial slider overlays, click-to-type, ctrl+click reset and mouse-wheel editing from a single control. A stock drag widget offers one of these. The price is that the editor must produce its own lifecycle flags, and this is where the sharp edges live.

### What each interaction returns

Here is the lifecycle for each gesture, as the trace found it. Read the frame sequences top to bottom:

| Gesture | Frame sequence |
|---------|----------------|
| Dial press | `IsItemActivated` sets state Dialing, stores `_startValue = value` and `_activeJogDialId` (231-237). That frame returns `Nothing` by fallthrough (299). |
| Dial drag | While `componentId == _activeJogDialId` and Dialing, `modified = true` (98). The overlay mutates `_editValue`, a smoothed value is written to `value` (139-140, 209), and the frame returns `Modified` (221). |
| Dial release | `IsMouseReleased` returns to Inactive and resets `_activeJogDialId = 0` (109-127, 335). Returns `Finished` without `Modified` (216-218). |
| Click, no drag | Enters TextInput. Ctrl+click returns `ResetToDefault` (117). |
| Text input | `Modified` per valid edit, otherwise `Started` (221). Exit returns `Finished`. |
| Mouse wheel | Hover returns `Started` (294). Each tick returns `Modified` (278). The first non-wheel frame returns `ModifiedAndFinished` (284-285). |

Notice that the overlays (`JogDialOverlay`, `InfinitySliderOverlay`, `SliderLadder`, `RadialSliderOverlay`) are pure `ref double` mutators with no reference to commands at all. `SingleValueEdit.DrawValueEditMethod` dispatches them (`SingleValueEdit.cs:302-321`, call site 139). That separation is good design, and the Rust section returns to it.

---

## The Translator: Turning Flags Into a Command

Between the widget and the stack stands one function, `ParameterWindow.HandleInputEditState` (`Editor/Gui/Windows/ParameterWindow.cs:848-882`). `DrawParameters` calls it at line 825, and `SnapshotControlView` shares it (doc comment at 845-846). Gradient and transform editors copy the same pattern by hand: `GradientUi.cs:33,75-90`, `GradientSliderUi.cs:38,74-90`, `TransformGizmoHandling.cs:379,636,932`.

Before the translator runs, the widget has already done its work. The entry point `InputValueUi<T>.DrawParameterEdit` (`Editor/UiModel/InputsAndTypes/InputValueUi.cs:132`) calls `DrawNormalParameter` (482), which:

1. Assigns `default` to the input when it was flagged IsDefault (612-614).
2. Calls `DrawValueControl` (617), which writes the live value into the input.
3. Invalidates the slot on `Modified | Finished` (618-622).
4. Clears IsDefault on `Modified` (630).

So by the time any command exists, the model holds the new value and the graph is already recomputing. Here is the translator's logic in condensed form, with the trace's line numbers:

```
Started : _inFlight = new ChangeInputValueCommand(sym, childId, input, input.Value, instance)   // 857
Modified: if null || other slot -> create (lazy, 862-867)
          _inFlight.AssignNewValue(input.Value); slot.DirtyFlag.Invalidate()                     // 869
Finished: if inFlight && same slot -> UndoRedoStack.Add(inFlight); inFlight = null              // 875-880
```

The in-flight command lives in two static fields, `_inputValueCommandInFlight` and `_inputSlotForActiveCommand` (`ParameterWindow.cs:1017-1018`). There is exactly one, shared across the whole window, and it is keyed by slot. A `Modified` for a different slot replaces it.

### Why `Add` and not `AddAndExecute`

`UndoRedoStack` offers both (`Editor/UiModel/Commands/UndoRedoStack.cs`). `AddAndExecute` is `Add` plus `Do` (34-39). On `Finished` the translator calls plain `Add` (875-880), because the value was applied live during the drag. Calling `Do` again would apply the change a second time for no benefit. The stack is the shelf, and `Add` shelves the receipt without replaying the take.

### Why the command is created before the first mutation

The command constructor snapshots the old value. If you construct it after the widget wrote the first new value, the "before" is already contaminated. That is why the translator wants `Started`, and why the lazy path at 862-867 exists as a fallback: some widgets (the dial) never return `Started` on the activation frame.

---

## ChangeInputValueCommand: A Receipt That Stores Ids, Not Objects

`Editor/UiModel/Commands/Graph/ChangeInputValueCommand.cs` is the "tape". Two design choices matter.

**It stores ids only.** The command keeps `_inputParentSymbolId`, `_childId` and `_inputId` (17-20, 156-158), not references to the live instance or slot. Undo and redo re-resolve them through the symbol graph. The apparent payoff is that a command holds no live object that can go stale between the edit and the undo (this is also why the throw-on-missing-symbol behavior below matters).

**It snapshots at construction.** The constructor records `_wasAnimated`, `_wasDefault`, `_animationTime`, `OriginalValue = input.Value.Clone()`, and the `_newValue` slot (21-25). If the input is animated it also stores `_originalKeyframes` (27-35), because editing an animated parameter at a given time changes keyframes, not a plain value.

The behavior is then small:

- `Do` calls `AssignValue(_newValue)` (89).
- `AssignNewValue` overwrites `_newValue` and applies it immediately (92-96). This is what the per-frame `Modified` handling calls, so the command's "after" always tracks the latest frame.
- `Undo` has three branches: animated restores keys via `SetTimeKeys(originalKeyframes)` (62); was-default calls ResetToDefault (76); otherwise it assigns `OriginalValue` (81).

The was-default branch is subtle and worth stealing: undoing the first edit of a never-touched parameter should return it to the "inherits default" state, not to a stored copy of the default. Otherwise later changes to the default would not flow through.

---

## Gestures That Touch Many Things: MacroCommand

A single parameter is easy. A multi-node drag is a different animal, so tixl adds a composite.

`Editor/UiModel/Commands/MacroCommand.cs` is a list of children with two ways to add them. `AddExecutedCommandForUndo` only appends (23), the "receipt" mode. `AddAndExecCommand` appends and runs `Do` now (31-35). `Do` runs children in order (39), `Undo` in reverse (44-47), and `IsUndoable` is the AND of the children (18).

### Trace: dragging three nodes and snapping one onto a connection

Let's follow a MagGraph drag from mouse press to Ctrl+Z.

1. The state machine enters `DragItems`, which calls `StartDragOperation` (`Editor/Gui/MagGraph/States/GraphStates.cs:331-337`).
2. That calls `StartMacroCommand("Move nodes")` (`Editor/Gui/MagGraph/Interaction/MagItemMovement.cs:647`). The context asserts no macro is already open (`Editor/Gui/MagGraph/States/GraphUiContext.cs:175`).
3. It creates a `ModifyCanvasElementsCommand`, whose constructor snapshots the original positions (`Editor/UiModel/Commands/Graph/ModifyCanvasElementsCommand.cs:29,130`), and adds it with `AddExecutedCommandForUndo` (`MagItemMovement.cs:649-650`). Nothing is re-executed; the macro is just holding the receipt.
4. During the drag, positions are mutated directly each frame. No command is touched.
5. When the drag snaps or splits a connection, those structural edits are added with `AddAndExecCommand` (e.g. `MagItemMovement.cs:712, 772, 1216`), or a fresh move command is created (766-770). These are real edits that have not happened yet, so they must execute.
6. On mouse release (`GraphStates.cs:340-342`), `CompleteDragOperation` calls `MoveElementsCommand.StoreCurrentValues()` (`MagItemMovement.cs:66`), folds slow-grow and section growth (67-68), and calls `context.CompleteMacroCommand()` (69). That pushes the macro with `UndoRedoStack.Add(MacroCommand)` (`GraphUiContext.cs:186-190`).
7. Ctrl+Z undoes the macro: children in reverse, so the connection split comes undone before the positions are restored.

`ModifyCanvasElementsCommand` stores originals at construction, finals in `StoreCurrentValues` (45-64), and re-resolves selectables by id in `Undo`/`Do` (66-109). Same ids-only principle as the value command.

The macro API has three entry points: `StartMacroCommand` (asserts null, `GraphUiContext.cs:175`), `StartOrContinueMacroCommand` (180), and `CancelMacroCommand`, which calls `MacroCommand.Undo()` (193-197). Note what cancel means: since the live model was mutated, cancelling has to undo the changes. It is used in placeholder and tree-layout flows (`GraphStates.cs:519,677`, `PlaceholderCreation.cs:287`). The drag state itself has no Escape handling (`GraphStates.cs:338-349`).

For the full movement and undo story see [../maggraph/09-interaction-movement.md](../maggraph/09-interaction-movement.md) and [../maggraph/19-undo-redo.md](../maggraph/19-undo-redo.md). The command catalogue lives in [../commands/01-symbol-commands.md](../commands/01-symbol-commands.md).

### The stack itself is deliberately dumb

`UndoRedoStack.cs` is two plain stacks (104-105). `Add` pushes and clears redo if the command `IsUndoable`; otherwise it clears the entire stack (41-52). `Undo` pops, calls `Undo`, pushes onto redo (59-69). There is no merging, no coalescing and no size cap. All grouping intelligence lives in the callers.

---

## Stated Rule vs. Code

> The project's agent guidance (`.agentic/AGENT_INSTRUCTIONS.md`) says:
>
> - Line 372: any mutation "must go through a command (`UndoRedoStack.AddAndExecute(...)`)".
> - Line 373: "For drag interactions: construct the command on drag start, update its target values during the drag, push to the undo stack on drag complete, not on every mouse-move."
>
> The code follows 373, but uses `Add` rather than `AddAndExecute`, because the value is already live. The rule never mentions the distinction, so a reader following 372 literally would double-apply. The dial path also creates its command lazily at the first `Modified`, not "on drag start", because `Started` is not returned on activation (inferred from code).
>
> A second deviation: line 52 of the same file says a missing symbol should warn and no-op, but `ChangeInputValueCommand` throws in `Undo` and `AssignValue` when the symbol is missing (41, 101).

The lesson is not that the docs are bad. It is that "all mutation goes through a command" is false for live-drag editing by construction, and a rule worth writing should say which of the two stack calls to use and why.

---

## Gotchas

Here is where the design gets sharp. These come from the trace. Items marked *inferred from code, not verified at runtime* come from reading, not running.

- **No cancel mid-drag.** Dialing has no Escape handling; release or `IsItemDeactivated` returns `Finished` (109-136). In TextInput, Esc sets `completedAfterFocusLoss` (175), `modified` becomes false, state goes Inactive and the frame returns `Finished` with `value = _editValue` (175-218). `_editValue` reverts to `_startValue` only when it is NaN (189-190). So Esc appears to commit the typed text rather than revert it (*inferred from code, not verified at runtime*).
- **Possible lost final value.** The `Finished` frame does not carry `Modified`, so `AssignNewValue` is not called with the final value. The dial writes `_dampedValue` while Dialing but `_editValue` after going Inactive (207-214). The value written to the model may differ from the command's `_newValue`, and redo could replay the penultimate value (*inferred from code, not verified at runtime*).
- **Text input re-creates the command.** Non-modified text frames return `Started` (221), and `Started` always constructs a new command (`ParameterWindow.cs:853-858`). After the first keystroke the second command's `OriginalValue` is already the edited value, so undo may be a no-op (*inferred from code, not verified at runtime*).
- **Hover starts an edit.** The wheel path returns `Started` on mere hover (`SingleValueEdit.cs:294`). A command is created that may never finish, and it is reused if the same slot gets `Modified` later (`ParameterWindow.cs:862`) (*inferred from code, not verified at runtime*).
- **No separate preview state.** The model is committed every frame; the stack gets an entry only at the end. Aborts cannot revert except via `CancelMacroCommand`.
- **A non-undoable `Add` wipes everything.** One command that reports `IsUndoable == false` clears the entire stack (`UndoRedoStack.cs:48-51`).
- **The rules lag the code.** `AGENT_INSTRUCTIONS.md:56` still names `MoveTimeClipsCommand` as a command that holds `Instance` references, but it has already been fixed: it stores the composition's id path (`Editor/UiModel/Commands/Animation/MoveTimeClipsCommand.cs:28,32`) and re-resolves it on each Do/Undo (`:146-151`). Treat written rules as intent and check the code (see [04 — Retained state](04-retained-state.md)).
- **Coverage gaps** per `.agentic/Plans/Plan_UndoRedoCoverage.md`: open items are #12 playback/BPM, #15 tour points, #17 auto-layout (`NodeGraphLayouting.cs:58`), with #19-20 to investigate. #13 StructuredList is deferred because shallow-clone aliasing breaks `OriginalValue`. Residual: `CreateOrUpdateSnapshotVariation` produces two undo entries (line 74).

---

## Translating to Rust and dear-imgui-rs

### Adopt

- **Ids-only commands with snapshot-at-construction.** Keys instead of references means the undo stack never fights the borrow checker or dangling nodes.
- **Receipt semantics.** `commit(cmd, already_applied)` is a better name than the `Add`/`AddAndExecute` pair, and it removes the double-apply trap.
- **Widgets as pure mutators.** Keep overlays as `&mut f64` functions that know nothing about history.
- **MacroCommand with reverse undo**, plus one macro per gesture.
- **One in-flight edit keyed by slot.**

### Modify

- **Derive the lifecycle from ImGui, not from a hand-rolled machine.** On a stock drag or input widget, `is_item_activated` marks start and `is_item_deactivated_after_edit` marks finish. Only build a custom state machine if you need the multi-overlay widget.
- **Make `Finished` carry the final value**, so the command's `after` is always what the model holds.
- **Snapshot on activation, never on hover.**
- **Coalesce in the commit path** (same key and gesture, replace `after`) instead of relying on every caller to be careful.

### Avoid

- **Throwing on a missing node during undo.** Decide on a policy (skip with a warning) and apply it uniformly.
- **Wiping the whole stack on a non-undoable command.** Prefer a barrier marker or refuse the edit.
- **Commands holding live references.**
- **Cancel that depends on undoing live mutation.** Give drags a real revert.

### A small sketch

This is a generic sketch, not a drop-in implementation. It shows the shape: an explicit edit-state enum, a command holding keys plus before and after, one in-flight edit, and a commit that takes a flag for whether the change is already live.

```rust
#[derive(Clone, Copy, PartialEq, Eq)]
enum EditState { Idle, Started, Modified, Finished, Cancelled }

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct EditKey { node: u64, param: u64 }

struct Edit { key: EditKey, before: Value, after: Value }

trait Command { fn apply(&self, m: &mut Model); fn revert(&self, m: &mut Model); }

struct Editor {
    in_flight: Option<Edit>,        // at most one, keyed by (node, param)
    undo: Vec<Box<dyn Command>>,
    redo: Vec<Box<dyn Command>>,
}

impl Editor {
    // `already_applied` = the widget wrote the value live; do not apply again.
    fn commit(&mut self, cmd: Box<dyn Command>, already_applied: bool, m: &mut Model) {
        if !already_applied { cmd.apply(m); }
        self.redo.clear();
        self.undo.push(cmd);
    }
}
```

Next, the per-frame translation. The widget returns an `EditState`; the editor snapshots before mutation, tracks the latest value, and treats a revert as a real operation.

```rust
fn param_row(ui: &Ui, ed: &mut Editor, m: &mut Model, key: EditKey) {
    let mut v = m.get(key);
    let changed = ui.slider("##p", 0.0, 1.0, &mut v);   // widget mutates the local copy

    // Snapshot on activation, BEFORE writing the new value to the model.
    if ui.is_item_activated() {
        ed.in_flight = Some(Edit { key, before: m.get(key), after: m.get(key) });
    }
    if changed {
        m.set(key, v);                                   // live preview
        if let Some(e) = ed.in_flight.as_mut().filter(|e| e.key == key) {
            e.after = v;                                 // coalesce: keep latest
        }
    }
    // Real cancel: Escape while active restores `before` and drops the edit.
    if ui.is_item_active() && ui.is_key_pressed(Key::Escape) {
        if let Some(e) = ed.in_flight.take() { m.set(e.key, e.before); }
        return;
    }
    // Finish: one entry per gesture, already applied.
    if ui.is_item_deactivated() {
        if let Some(e) = ed.in_flight.take().filter(|e| e.key == key && e.before != e.after) {
            ed.commit(Box::new(SetParam::from(e)), true, m);
        }
    }
}
```

A few notes on the sketch. The `before != after` check means a click that changes nothing leaves no history. The Escape branch is the cancel tixl lacks: because the editor holds `before`, it can restore without touching the stack. The ImGui calls (`is_item_activated`, `is_item_active`, `is_item_deactivated`, `is_key_pressed(Key::Escape)`) match dear-imgui-rs 0.8; `Value`, `Editor` and `Model` stand in for your own types. For multi-node moves, hold a `Vec<Edit>` (or a macro command) opened on drag start, mutate positions directly, and commit it once on release, with the same Escape-restores-originals rule.

---

## Next Steps

- [../maggraph/19-undo-redo.md](../maggraph/19-undo-redo.md): the MagGraph undo story in full.
- [../maggraph/09-interaction-movement.md](../maggraph/09-interaction-movement.md): the movement state machine that drives the macro trace above.
- [../commands/01-symbol-commands.md](../commands/01-symbol-commands.md): the catalogue of commands.
- [../maggraph/B-imgui-patterns.md](../maggraph/B-imgui-patterns.md): broader ImGui patterns used across the graph editor.
