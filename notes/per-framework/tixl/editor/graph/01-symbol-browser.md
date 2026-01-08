# Chapter 1: The Symbol Browser Popup

> *Press Tab anywhere on the canvas, and within milliseconds you're searching thousands of operators—filtered by type, ranked by relevance, ready to wire.*

**Previous:** [Index](00-index.md) | **Next:** [Search & Relevance Scoring](02-search-relevance.md)

---

## The Problem: Finding the Right Operator in a Sea of Thousands

Picture yourself composing a visual effects scene. You have a `Texture2D` output from a noise generator, and you want to apply a blur effect. Somewhere in the library of 500+ operators, there's exactly what you need—but how do you find it without breaking your creative flow?

The naive solution is a dockable tree browser. Expand "Lib > Image > Processing > Blur"—click, click, click. By the time you've found it, you've forgotten what you were trying to achieve. Even with search, switching focus to a separate window breaks the rhythm of wiring nodes together.

What if the library came to you? What if pressing a single key opened a context-aware picker right where your cursor is, already filtered to show only operators that accept textures as input?

That's what the SymbolBrowser does. It's a **command palette for visual programming**—think VS Code's Ctrl+P, but designed for node graphs. It appears where you need it, shows what's relevant, and disappears the moment you've made your choice.

---

## The Mental Model: Autocomplete Meets Type Safety

The SymbolBrowser isn't just a search box. It's more like the autocomplete popup in a typed programming language. When you call a method that returns `String`, your IDE only suggests methods that accept strings. The SymbolBrowser applies the same principle to visual programming:

- **Dragging from an output?** Only operators with compatible inputs appear
- **Dragging from an input?** Only operators with compatible outputs appear
- **Multiple connections?** Shows operators with multi-input slots

This context-awareness transforms operator discovery from "search the entire library" to "pick from a short list of things that will actually work." The type system becomes your guide rather than a constraint.

---

## How It Looks: Anatomy of the Browser

When you press Tab or drop a connection on empty canvas, the browser appears:

```
┌────────────────────────────────────────────┐
│  [Search Input: "blur_____"]               │
├────────────────────────────────────────────┤
│  Texture2D -> Texture2D                    │  ← Type filter header
├────────────────────────────────────────────┤
│ ▶ Blur                     Lib.Image       │  ← Selected (highlighted)
│   DirectionalBlur          Lib.Image       │
│   RadialBlur               Lib.Image       │
│   ZoomBlur                 Lib.Image       │
│   MotionBlur               Lib.Image       │
│   ...                                      │
├────────────────────────────────────────────┼───────────────────┐
│                                            │  Applies gaussian │
│                                            │  blur with        │
│                                            │  configurable     │
│                                            │  radius...        │
│                                            │                   │
│                                            │  ▸ Example: BlurDemo
└────────────────────────────────────────────┴───────────────────┘
        Results List (scrollable)                Description Panel
```

Three key regions work together:

1. **Search Input** — Where you type; fuzzy matching means "ds" finds "DrawState"
2. **Results List** — Filtered, ranked operators; keyboard-navigable
3. **Description Panel** — Shows selected operator's documentation and example links

When type filtering is active, a header appears showing the constraint: `Texture2D -> Texture2D` tells you at a glance why you're seeing this subset.

---

## Trigger Conditions: When Does It Open?

The SymbolBrowser responds to three distinct user actions, each with different initialization:

### 1. Tab Key with No Selection

The simplest case: you're looking at an empty area of canvas and want to add a new operator.

```
User presses Tab
    ↓
ConnectionMaker.StartOperation() → prepares undo context
    ↓
SymbolBrowser.OpenAt(mousePosition, inputType: null, outputType: null)
    ↓
No type filtering, full library available
```

This is "free exploration" mode—you see the entire operator library, ranked by relevance to your current project.

### 2. Tab Key with Single Selection

When exactly one node is selected, Tab does something smarter: it prepares to insert a new operator *after* the selected one, preserving any existing connections.

```
User selects node "NoiseGenerator" (outputs Texture2D)
User presses Tab
    ↓
ConnectionMaker.OpenBrowserWithSingleSelection()
    ↓
Finds downstream connections from NoiseGenerator
Deletes them (stored for reconnection later)
    ↓
SymbolBrowser.OpenAt(position, inputType: Texture2D, outputType: Texture2D)
    ↓
Shows operators that accept Texture2D AND output Texture2D
```

The key insight: if NoiseGenerator was connected to downstream nodes, those connections are temporarily severed. When you pick an operator, the SymbolBrowser reconnects everything:

```
Before: NoiseGenerator ──→ ColorGrade
After:  NoiseGenerator ──→ Blur ──→ ColorGrade
```

This "insert after" behavior happens automatically when a node is selected.

### 3. Connection Dropped on Empty Canvas

The most context-rich trigger. You drag a connection line from a slot and release it on empty space:

```
User drags from output slot (type: Command)
User releases on empty canvas
    ↓
ConnectionMaker.InitSymbolBrowserAtPosition()
    ↓
SymbolBrowser.OpenAt(dropPosition, inputType: Command, outputType: null)
    ↓
Shows only operators with Command input
```

If you drag from an *input* slot instead, the filtering inverts—only operators with matching outputs appear.

---

## The Type Filtering System

Type filtering is what makes the SymbolBrowser feel intelligent. Let's trace how it works.

### Setting Up the Filter

When `OpenAt()` is called, it initializes a `SymbolFilter` instance with type constraints:

```csharp
public void OpenAt(Vector2 positionOnCanvas,
                   Type filterInputType,      // Required input type (or null)
                   Type filterOutputType,     // Required output type (or null)
                   bool onlyMultiInputs,      // Only show variadic operators?
                   ...)
{
    _filter.FilterInputType = filterInputType;
    _filter.FilterOutputType = filterOutputType;
    _filter.OnlyMultiInputs = onlyMultiInputs;
    _filter.UpdateIfNecessary(_components.NodeSelection, forceUpdate: true);
    // ...
}
```

### How Matching Works

The type filtering logic lives in `SymbolFilter.cs`, not in `SymbolBrowser.cs`. The browser delegates all filtering to its `_filter` instance, which iterates through all registered operators checking each against the constraints:

```csharp
// In SymbolFilter.UpdateMatchingSymbols()
foreach (var symbolUi in EditorSymbolPackage.AllSymbolUis)
{
    var symbol = symbolUi.Symbol;

    // Input type constraint: does the operator accept this type?
    if (_inputType != null)
    {
        var matchingInput = symbol.GetInputMatchingType(_inputType);
        if (matchingInput == null)
            continue;  // Skip—no compatible input

        // Multi-input constraint
        if (OnlyMultiInputs && !symbol.InputDefinitions[0].IsMultiInput)
            continue;  // Skip—not variadic
    }

    // Output type constraint: does the operator produce this type?
    if (_outputType != null)
    {
        var matchingOutput = symbol.GetOutputMatchingType(_outputType);
        if (matchingOutput == null)
            continue;  // Skip—no compatible output
    }

    // Passed all filters—add to results
    MatchingSymbolUis.Add(symbolUi);
}
```

The `GetInputMatchingType()` and `GetOutputMatchingType()` methods walk the operator's slot definitions looking for a type match. They consider inheritance—if your filter asks for `Texture2D`, an operator accepting `TextureBase` will still match.

### Visual Feedback

When type filtering is active, the browser displays a header showing the active constraint:

```csharp
private void PrintTypeFilter()
{
    if (_filter.FilterInputType == null && _filter.FilterOutputType == null)
        return;

    var inputTypeName = _filter.FilterInputType != null
        ? TypeNameRegistry.Entries[_filter.FilterInputType]
        : string.Empty;

    var outputTypeName = _filter.FilterOutputType != null
        ? TypeNameRegistry.Entries[_filter.FilterOutputType]
        : string.Empty;

    var isMultiInput = _filter.OnlyMultiInputs ? "[..]" : "";

    var headerLabel = $"{inputTypeName}{isMultiInput}  -> {outputTypeName}";
    ImGui.TextDisabled(headerLabel);
}
```

So you might see: `Texture2D  -> ` (filtering by input only), `-> Command` (filtering by output only), or `float[..]  -> float` (variadic float-to-float operators).

### Namespace Relevance Fading

Not all matching operators are displayed equally. The results list applies visual fading to symbols from less relevant namespaces. Operators from `Lib.`, `Types.`, `Examples.Lib.`, the current project namespace, or the current composition's namespace appear at full opacity. Everything else is faded to 40% opacity:

```csharp
var isRelevantNamespace = symbolNamespace.StartsWith("Lib.")
                          || symbolNamespace.StartsWith("Types.")
                          || symbolNamespace.StartsWith("Examples.Lib.")
                          || symbolNamespace.StartsWith(projectNamespace)
                          || symbolNamespace.StartsWith(compositionNameSpace);

if (!isRelevantNamespace)
{
    color = color.Fade(0.4f);
}
```

This visual distinction helps you quickly identify "core library" operators versus less commonly used ones, without hiding any options entirely.

---

## UI Rendering: The Draw Loop

Each frame, `Draw()` orchestrates the entire browser UI. Let's trace through its structure.

### Frame Entry

```csharp
public void Draw()
{
    if (!IsOpen)
    {
        // Check for Tab key to open
        // ... (covered in Trigger Conditions above)
        return;
    }

    FrameStats.Current.OpenedPopUpName = "SymbolBrowser";
    _filter.UpdateIfNecessary(_components.NodeSelection);

    // ... rendering begins
}
```

The filter updates first—if the search string changed since last frame, results need recalculation.

### Positioning

The browser positions itself relative to the drop point on canvas, then clamps to stay within window bounds:

```csharp
var browserPositionInWindow = posInWindow + BrowserPositionOffset;
var browserSize = ResultListSize;  // 250x300 scaled by UI factor

ClampPanelToCanvas(_graphView, ref browserPositionInWindow, ref browserSize);
```

The clamping logic ensures the browser never extends beyond the visible canvas:

```csharp
private static void ClampPanelToCanvas(IGraphView graphView,
                                        ref Vector2 position,
                                        ref Vector2 size)
{
    var windowSize = graphView.Canvas.WindowSize;

    // Shift left if would overflow right edge
    var maxXPos = position.X + size.X;
    if (maxXPos > windowSize.X)
        position.X += windowSize.X - maxXPos;

    // Shrink height if would overflow bottom edge
    var maxYPos = position.Y + size.Y;
    if (maxYPos > windowSize.Y)
        size.Y += windowSize.Y - maxYPos;
}
```

Notice that horizontal overflow causes a *shift* (the panel moves left), while vertical overflow causes *shrinking* (the list gets shorter). This keeps the search input always visible at the expected position.

### Component Drawing Order

The browser draws its components in a specific order—results list, then description panel, then search input:

```csharp
DrawResultsList(browserSize);

if (_selectedSymbolUi != null)
{
    if (_filter.PresetFilterString != string.Empty)
    {
        // Preset mode: show presets panel
        DrawPresetPanel(browserPositionInWindow, new Vector2(140, browserSize.Y));
    }
    else
    {
        // Normal mode: show description panel
        DrawDescriptionPanel(browserPositionInWindow, browserSize);
    }
}

DrawSearchInput(posInWindow, _posInScreen, _size * T3Ui.UiScaleFactor);
```

Why this order? The search input is drawn last so that `SetKeyboardFocusHere()` (called on the first frame) correctly targets the input field. ImGui's focus system operates on the *next* widget to be drawn, so the focus call in `DrawSearchInput` must happen immediately before the `InputText` widget.

---

## Keyboard Navigation

The SymbolBrowser is designed for keyboard-first interaction. Here's the complete control scheme:

| Key | Action |
|-----|--------|
| `Tab` | Open browser (when closed) |
| `Typing` | Filter results (fuzzy match) |
| `↓` / `↑` | Navigate results list |
| `Enter` | Create selected operator |
| `Escape` | Cancel and close |
| Click outside | Cancel and close |

### Arrow Key Handling

Navigation happens in `DrawResultsList()`:

```csharp
if (ImGui.IsKeyReleased((ImGuiKey)Key.CursorDown))
{
    UiListHelpers.AdvanceSelectedItem(_filter.MatchingSymbolUis, ref _selectedSymbolUi, 1);
    _selectedItemChanged = true;
}
else if (ImGui.IsKeyReleased((ImGuiKey)Key.CursorUp))
{
    UiListHelpers.AdvanceSelectedItem(_filter.MatchingSymbolUis, ref _selectedSymbolUi, -1);
    _selectedItemChanged = true;
}
```

`AdvanceSelectedItem` is a utility from `UiListHelpers` that advances the selection by a given delta. The wrap-around behavior at list boundaries is assumed based on typical list navigation patterns.

When selection changes, the list scrolls to keep the selected item visible:

```csharp
if (_selectedItemChanged && _selectedSymbolUi == symbolUi)
{
    UiListHelpers.ScrollToMakeItemVisible();
    _selectedItemChanged = false;
}
```

### Enter Key: Instance Creation

When you press Enter, the search input handler triggers creation:

```csharp
if (ImGui.IsKeyPressed((ImGuiKey)Key.Return))
{
    if (_selectedSymbolUi != null)
    {
        CreateInstance(_selectedSymbolUi.Symbol);
    }
}
```

We'll cover `CreateInstance()` in detail shortly.

### Escape and Click-Outside: Cancellation

Multiple conditions trigger cancellation:

```csharp
var clickedOutside = ImGui.IsMouseClicked(ImGuiMouseButton.Left)
                     && ImGui.IsWindowHovered();
var shouldCancel = clickedOutside
                   || ImGui.IsMouseClicked(ImGuiMouseButton.Right)
                   || ImGui.IsKeyDown((ImGuiKey)Key.Esc);

if (shouldCancel)
{
    Cancel();
}
```

A subtle detail: `ImGui.IsWindowHovered()` returns true when the mouse is *over* the window, so `clickedOutside` actually triggers when you click *inside* the browser window but not on an interactive element. The naming is counterintuitive, but the effect is that clicking on empty space within the browser (like the background) cancels the operation, while clicking on results selects them.

Cancellation invokes `ConnectionMaker.AbortOperation()`, which undoes any preparatory commands (like temporarily deleted connections) and clears the browser state.

---

## The Preset Panel: Two-Part Search

Sometimes you don't just want an operator—you want a specific *configuration* of that operator. The SymbolBrowser supports "preset search" with a two-part query syntax:

```
"DrawState blur"
    ↓
Symbol filter: "DrawState"
Preset filter: "blur"
```

Typing a space followed by additional text switches into preset mode:

```csharp
// In SymbolFilter.UpdateFilters()
var twoPartSearchResult = new Regex(@"(.+?)\s+(.*)").Match(search);
if (twoPartSearchResult.Success)
{
    symbolFilter = twoPartSearchResult.Groups[1].Value;  // "DrawState"
    presetFilter = twoPartSearchResult.Groups[2].Value;  // "blur"
}
```

When a preset filter is active, the description panel is replaced by a preset panel:

```csharp
if (_filter.PresetFilterString != string.Empty && _selectedItemChanged)
{
    _matchingPresets.Clear();
    var presetPool = VariationHandling.GetOrLoadVariations(_selectedSymbolUi.Symbol.Id);
    if (presetPool != null)
    {
        _matchingPresets.AddRange(
            presetPool.AllVariations.Where(v =>
                v.IsPreset &&
                v.Title.Contains(_filter.PresetFilterString,
                                 StringComparison.InvariantCultureIgnoreCase)));
    }
}
```

The preset panel shows matching presets as a selectable list:

```
┌─────────────────────────┐
│ DrawState               │
│ Presets                 │
│                         │
│ ▶ GaussianBlur3x3       │
│   GaussianBlur5x5       │
│   MotionBlur            │
│   RadialBlur            │
└─────────────────────────┘
```

Selecting a preset and pressing Enter creates the operator with that preset's parameters pre-applied:

```csharp
var presetPool = VariationHandling.GetOrLoadVariations(_selectedSymbolUi.Symbol.Id);
if (presetPool != null && _selectedPreset != null)
{
    presetPool.Apply(newInstance, _selectedPreset);
}
```

---

## Instance Creation: From Selection to Wired Node

The culmination of a SymbolBrowser interaction is `CreateInstance()`. This method transforms your selection into a real node wired into the graph. Let's trace through it step by step.

Note: The browser also supports an `_overrideCreate` callback for custom creation logic. When set (via the `OpenAt` parameter), the callback receives the selected symbol and the standard creation flow is bypassed entirely. This escape hatch is used for specialized scenarios like creating operators in non-standard contexts.

### Step 1: Create the Node

```csharp
private void CreateInstance(Symbol symbol)
{
    var commandsForUndo = new List<ICommand>();
    var parentSymbol = _components.CompositionInstance.Symbol;

    var addSymbolChildCommand = new AddSymbolChildCommand(parentSymbol, symbol.Id)
    {
        PosOnCanvas = PosOnCanvas
    };
    commandsForUndo.Add(addSymbolChildCommand);
    addSymbolChildCommand.Do();
```

`AddSymbolChildCommand` is an undo-able command that adds a new child node to the parent symbol. The position was captured when the browser opened.

### Step 2: Retrieve the New Node's UI Model

```csharp
    var parentSymbolUi = parentSymbol.GetSymbolUi();
    if (!parentSymbolUi.ChildUis.TryGetValue(addSymbolChildCommand.AddedChildId, out var newChildUi))
    {
        Log.Warning("Unable to create new operator");
        return;
    }

    var newSymbolChild = newChildUi.SymbolChild;
    var newInstance = _components.CompositionInstance.Children[newChildUi.Id];
```

The command gives us the ID of the newly created child. We look it up to get both the UI representation (`newChildUi`) and the runtime instance (`newInstance`).

### Step 3: Apply Preset (if selected)

```csharp
    var presetPool = VariationHandling.GetOrLoadVariations(_selectedSymbolUi.Symbol.Id);
    if (presetPool != null && _selectedPreset != null)
    {
        presetPool.Apply(newInstance, _selectedPreset);
    }
```

If the user selected a preset via two-part search, its parameter values are applied now.

### Step 4: Update Selection

```csharp
    _components.NodeSelection.SetSelection(newChildUi, newInstance);
```

The new node becomes selected. This provides visual feedback and prepares for potential next actions.

### Step 5: Wire the Connections

This is where the SymbolBrowser shows its intelligence. The `ConnectionMaker` has been holding "temporary connections"—placeholders indicating what should connect to the new node. Now we realize those placeholders as real connections:

```csharp
    var tempConnections = ConnectionMaker.GetTempConnectionsFor(_graphView);

    foreach (var c in tempConnections)
    {
        switch (c.GetStatus())
        {
            case TempConnection.Status.SourceIsDraftNode:
                // Connection goes FROM our new node TO something else
                var outputDef = newSymbolChild.Symbol.GetOutputMatchingType(c.ConnectionType);
                var newConnection = new Symbol.Connection(
                    sourceParentOrChildId: newSymbolChild.Id,
                    sourceSlotId: outputDef.Id,
                    targetParentOrChildId: c.TargetParentOrChildId,
                    targetSlotId: c.TargetSlotId);
                var addCommand = new AddConnectionCommand(parentSymbol, newConnection, c.MultiInputIndex);
                addCommand.Do();
                commandsForUndo.Add(addCommand);
                break;

            case TempConnection.Status.TargetIsDraftNode:
                // Connection goes FROM something else TO our new node
                var inputDef = newSymbolChild.Symbol.GetInputMatchingType(c.ConnectionType);
                var newConnectionToInput = new Symbol.Connection(
                    sourceParentOrChildId: c.SourceParentOrChildId,
                    sourceSlotId: c.SourceSlotId,
                    targetParentOrChildId: newSymbolChild.Id,
                    targetSlotId: inputDef.Id);
                var connectionCommand = new AddConnectionCommand(parentSymbol, newConnectionToInput, 0);
                connectionCommand.Do();
                commandsForUndo.Add(connectionCommand);
                break;
        }
    }
```

The key insight: `GetOutputMatchingType()` and `GetInputMatchingType()` find the *first* slot of the new operator that matches the required type. This is why type filtering matters—we already know a compatible slot exists.

### Step 6: Finalize the Operation

```csharp
    ConnectionMaker.CompleteOperation(_graphView, commandsForUndo,
                                      "Insert Op " + newChildUi.SymbolChild.ReadableName);
    ParameterPopUp.NodeIdRequestedForParameterWindowActivation = newSymbolChild.Id;
    Close();
}
```

`CompleteOperation` bundles all the commands into a single undoable unit. If you press Ctrl+Z, the entire "create node and wire connections" operation reverses as one action.

The parameter popup is optionally triggered, letting you immediately tweak the new node's settings.

---

## Code Trace: Tab with No Selection

Let's walk through the complete flow when you press Tab on empty canvas:

```
1. User presses Tab key (no node selected)
   ↓
2. Draw() detects Tab release with IsOpen=false
   → Checks: IsKeyReleased(Tab)? ✓
   → Checks: SelectedChildUis.Count() != 1? ✓ (0 selected)
   ↓
3. ConnectionMaker.StartOperation("Add operator")
   → Creates MacroCommand for undo grouping
   → Initializes TempConnections list (empty)
   ↓
4. Calculate position: mouse pos → canvas coordinates
   ↓
5. OpenAt(canvasPosition, inputType: null, outputType: null, onlyMultiInputs: false)
   → _filter.FilterInputType = null (no constraint)
   → _filter.FilterOutputType = null (no constraint)
   → _filter.UpdateIfNecessary(forceUpdate: true)
       → Iterates all 500+ symbols
       → No type filtering (both null)
       → Applies search string filter (empty = match all)
       → Sorts by relevancy, takes top 100
   → _selectedSymbolUi = first result (highest relevancy)
   → IsOpen = true
   ↓
6. Next frame: Draw() runs with IsOpen=true
   → ClampPanelToCanvas adjusts position
   → DrawResultsList renders 100 items
   → DrawDescriptionPanel shows first item's docs
   → DrawSearchInput shows empty text box
   ↓
7. User types "blur"
   → SearchString = "blur"
   → _filter.UpdateIfNecessary detects change
       → Regex pattern: "b.*l.*u.*r"
       → Filters to ~8 matching symbols
       → Re-ranks, Blur likely tops list
   → UI refreshes with filtered list
   ↓
8. User presses Enter
   → CreateInstance(_selectedSymbolUi.Symbol)
   → AddSymbolChildCommand creates Blur node
   → No temp connections (no type filter)
   → ConnectionMaker.CompleteOperation("Insert Op Blur")
   → Close()
```

---

## Code Trace: Dropping a Connection on Empty Canvas

Now let's trace the more complex case—dragging a connection and releasing on empty space:

```
1. User drags from "Noise" output slot (type: Texture2D)
   ↓
2. ConnectionMaker.StartFromOutputSlot(Noise, outputDef)
   → Creates MacroCommand
   → TempConnections.Add(new TempConnection(
       sourceParentOrChildId: Noise.Id,
       sourceSlotId: outputDef.Id,
       targetParentOrChildId: NotConnectedId,  // Incomplete
       targetSlotId: NotConnectedId,
       connectionType: Texture2D))
   ↓
3. User drags connection line (visual feedback)
   ↓
4. User releases on empty canvas
   ↓
5. ConnectionMaker.InitSymbolBrowserAtPosition(dropPosition)
   → Checks: TempConnections[0].TargetSlotId == NotConnectedId? ✓
   → Updates connection:
       TempConnections[0].TargetParentOrChildId = UseDraftChildId  // "Will connect to new node"
   → Calls: SymbolBrowser.OpenAt(dropPosition,
                                  inputType: Texture2D,  // FROM the drag
                                  outputType: null,       // No output constraint
                                  onlyMultiInputs: false)
   ↓
6. OpenAt initializes filter with constraints
   → _filter.FilterInputType = Texture2D
   → _filter.UpdateIfNecessary(forceUpdate: true)
       → Only operators with Texture2D-compatible input pass
       → Roughly 50 operators (image processing, effects, etc.)
   → Type header displays: "Texture2D  -> "
   ↓
7. User selects "Blur" and presses Enter
   ↓
8. CreateInstance(Blur.Symbol)
   → AddSymbolChildCommand creates Blur node
   → Loop through TempConnections:
       c.GetStatus() == TargetIsDraftNode ✓
       → inputDef = Blur.Symbol.GetInputMatchingType(Texture2D)
         (Returns first Texture2D input slot of Blur)
       → Creates connection: Noise.output → Blur.input
       → AddConnectionCommand.Do()
   → CompleteOperation("Insert Op Blur")
   → Close()
   ↓
9. Result: Noise ──Texture2D──→ Blur
```

---

## Edge Cases and Gotchas

### What Happens When No Operators Match?

If your type filter is highly restrictive (say, a custom type only accepted by 2 operators) and your search term matches neither, the results list is empty. The browser still displays—with an empty list—but there's nothing to select.

The code handles this gracefully:

```csharp
if (_selectedSymbolUi == null && _filter.MatchingSymbolUis.Count > 0)
{
    _selectedSymbolUi = _filter.MatchingSymbolUis[0];
}
// If count is 0, _selectedSymbolUi remains null
// Enter key does nothing (CreateInstance checks for null)
```

### Canvas Edge Behavior

When you open the browser near canvas edges, two things can happen:

1. **Auto-scroll on open**: If the drop position is too close to the window edge, the canvas scrolls to center it:

```csharp
var screenRect = ImRect.RectWithSize(screenPos, SymbolUi.Child.DefaultOpSize);
screenRect.Expand(200 * canvas.Scale.X);
var windowRect = ImRect.RectWithSize(ImGui.GetWindowPos(), ImGui.GetWindowSize());
var tooCloseToEdge = !windowRect.Contains(screenRect);

if (tooCloseToEdge)
{
    canvas.FitAreaOnCanvas(canvasRect);
}
```

2. **Panel clamping**: After scrolling, if the browser would still extend beyond bounds, it clamps (shifts left or shrinks vertically).

### Search Input Dragging

A subtle feature: you can drag the search input box to reposition the browser:

```csharp
if (ImGui.IsMouseDragging(ImGuiMouseButton.Left))
{
    PosOnCanvas += _graphView.Canvas.InverseTransformDirection(ImGui.GetIO().MouseDelta);
}
```

This is useful if the auto-positioned browser obscures something you need to see.

### Cycle Prevention

When inserting a node, the `SymbolFilter` prevents graph cycles by excluding parent symbols:

```csharp
// In UpdateMatchingSymbols()
ICollection<Guid> parentSymbolIds = new HashSet<Guid>(
    Structure.CollectParentInstances(compositionInstance)
        .Append(compositionInstance)
        .Select(p => p.Symbol.Id));

foreach (var symbolUi in EditorSymbolPackage.AllSymbolUis)
{
    // Prevent graph cycles
    if (parentSymbolIds.Contains(symbolUi.Symbol.Id))
        continue;
    // ...
}
```

You can't insert the current composition into itself, or any of its parents.

---

## Key Source Files

| File | LOC | Purpose |
|------|-----|---------|
| `Editor/Gui/Graph/Legacy/Interaction/SymbolBrowser.cs` | ~660 | Browser popup UI, instance creation |
| `Editor/UiModel/Helpers/SymbolFilter.cs` | ~390 | Search algorithm, type matching, relevancy |
| `Editor/Gui/Graph/Legacy/Interaction/Connections/ConnectionMaker.cs` | ~1100 | Connection state machine, temp connections |

---

## Summary

The SymbolBrowser solves operator discovery without breaking creative flow:

- **Context-aware**: Type filtering shows only compatible operators
- **Keyboard-first**: Tab to open, arrows to navigate, Enter to create
- **Position-aware**: Opens where you need it, clamps to visible bounds
- **Preset-enabled**: Two-part search finds configured variations
- **Undo-integrated**: Every action is reversible as a single unit

The magic isn't in any single feature—it's in how they combine. Dropping a connection opens a filtered list, selecting an item wires it automatically, and the whole operation undoes cleanly. That's the difference between "searching a library" and "having the library anticipate your needs."

---

**Next Chapter:** [Search & Relevance Scoring](02-search-relevance.md) — How the fuzzy matching algorithm ranks 500+ operators by relevance.
