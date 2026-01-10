# Chapter 1: The Symbol Library Window

> *A tree with thousands of leaves, yet finding any operator takes seconds—and reorganizing the hierarchy is just a drag away.*

## Key Insight

> **Symbol library's core idea:** A persistent docked window combining hierarchical tree browsing (for exploration) with flat search (for speed), plus drag-and-drop namespace reorganization and quality filters for finding operators needing attention.

**Previous:** [Index](00-index.md) | **Next:** [Namespace Tree & Filtering](02-namespace-tree.md)

---

## The Problem: Navigating Thousands of Operators

Picture this: you have a library of 500+ operators organized across dozens of namespaces. Some are yours, some came from the standard library, some are deprecated experiments you forgot to delete. You need to find a specific blur shader, but you cannot remember if it is under `Lib.Image.Filter`, `Lib.Fx.Blur`, or that custom namespace you created last week.

The naive solution is a flat list with a search box. Type "blur", get 47 results in alphabetical order. But alphabetical is meaningless—your custom blur should appear first, not buried after "BlurryText" from some abandoned project.

The other extreme is a deeply nested tree with no search at all. Expand folders, scroll, expand more folders. By the time you find the operator, you have forgotten why you needed it.

The Symbol Library solves this by combining both approaches: **a hierarchical tree for browsing, with search that flattens the view when active**. And because namespaces inevitably become disorganized, it adds **drag-and-drop reorganization**—no code edits required.

---

## The Mental Model: File Explorer Meets Bookmark Manager

Think of the Symbol Library as a hybrid between a file explorer and a bookmark manager:

- **File Explorer** — Operators nest inside namespaces like files in folders. A namespace like `Lib.Image.Filter` contains image filter operators. You can expand, collapse, and navigate the hierarchy.

- **Bookmark Manager** — You can "tag" operators for quick access. Quality filters let you see only operators missing documentation, or only unused ones. The search bar instantly filters the visible tree.

- **Drag-and-Drop** — Unlike a file system where moving files requires terminal commands or multiple clicks, the Symbol Library lets you drag any operator directly onto a namespace node to relocate it.

Unlike the Symbol Browser popup (which appears contextually when creating nodes), the Symbol Library is a **persistent docked window**. It is always visible, always browsable—the place you go when you are not sure what you are looking for.

---

## Window Structure: Anatomy of the Library

When you open the Symbol Library window, you see three main regions:

```
┌──────────────────────────────────────────────────────────────┐
│ [Search: blur____________]  [Refresh]  [Filter]              │
├──────────────────────────────────────────────────────────────┤
│  ▼ Lib                                                       │
│    ▼ Image                                                   │
│      ▼ Filter                                                │
│        [Blur]  [DirectionalBlur]  [RadialBlur]              │
│      ▶ Generate                                              │
│    ▶ Fx                                                      │
│  ▶ Types                                                     │
│  ▶ Examples                                                  │
│  ▼ MyProject                                                 │
│    [CustomBlur] ★                                            │
│                                                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

1. **Search Input** — A text field with placeholder text "Search symbols...". Empty shows the full tree; typing filters to a flat list.

2. **Action Buttons** — Refresh (rescans the library for dependency analysis) and Filter (shows quality checkboxes).

3. **Tree/List Area** — A scrollable region showing either the namespace tree or filtered search results.

Let us trace through the code that renders this.

### The Entry Point: DrawContent()

Every frame, the window's `DrawContent()` method orchestrates rendering:

```csharp
protected override void DrawContent()
{
    // [Note: Handle any open dialogs (rename, delete)]
    if (_subtreeNodeToRename != null)
        _renameNamespaceDialog.Draw(_subtreeNodeToRename);

    if (_symbolToDelete != null)
        _deleteSymbolDialog.Draw(_symbolToDelete);

    ImGui.PushStyleVar(ImGuiStyleVar.IndentSpacing, 10);

    if (_symbolUsageReferenceFilter != null)
    {
        DrawUsagesAReferencedSymbol();  // [Note: Alternative view: "what uses this symbol?"]
    }
    else
    {
        DrawView();  // [Note: Normal view: tree or search results]
    }

    ImGui.PopStyleVar(1);
}
```

The first thing to notice is the **mode switch**. If `_symbolUsageReferenceFilter` is set, the entire window transforms into a "usage reference" view—showing which operators depend on a selected symbol. Otherwise, `DrawView()` handles the normal tree-or-search display.

This modal behavior is a recurring pattern in the Tooll3 editor: rather than opening a new window, replace the current view in-place. The user stays in context.

### The Main View: DrawView()

```csharp
private void DrawView()
{
    var iconCount = 1;
    if (_wasScanned)
        iconCount++;

    CustomComponents.DrawInputFieldWithPlaceholder(
        "Search symbols...",
        ref _filter.SearchString,
        -ImGui.GetFrameHeight() * iconCount + 16);

    ImGui.SameLine();
    if (CustomComponents.IconButton(Icon.Refresh, Vector2.Zero, CustomComponents.ButtonStates.Dimmed))
    {
        _treeNode.PopulateCompleteTree();
        ExampleSymbolLinking.UpdateExampleLinks();
        SymbolAnalysis.UpdateDetails();
        _wasScanned = true;
    }

    CustomComponents.TooltipForLastItem(
        "Scan usage dependencies for symbols",
        "This can be useful for cleaning up operator name spaces.");

    if (_wasScanned)
    {
        _libraryFiltering.DrawSymbolFilters();
    }

    ImGui.BeginChild("scrolling", Vector2.Zero, false, ImGuiWindowFlags.NoBackground);
    {
        // [Note: Four-way branching determines what renders in the scrolling area]
        if (_libraryFiltering.AnyFilterActive)
        {
            DrawNode(FilteredTree);
        }
        else if (string.IsNullOrEmpty(_filter.SearchString))
        {
            DrawNode(_treeNode);
        }
        else if (_filter.SearchString.Contains('?'))
        {
            _randomPromptGenerator.DrawRandomPromptList();
        }
        else
        {
            DrawFilteredList();
        }
    }
    ImGui.EndChild();
}
```

Here is the **four-way branching** that determines what appears in the scrolling area:

| Condition | Result |
|-----------|--------|
| Quality filters active | Show filtered tree (operators with issues) |
| Search string empty | Show full namespace tree |
| Search contains `?` | Show random operator suggestions |
| Search has text | Show flat filtered list |

The question mark feature is a delightful discovery tool: type `???` and get three random operator suggestions. The number of question marks controls how many suggestions appear. This helps users stumble upon operators they might not know about.

---

## Tree Rendering: DrawNode() and DrawNodeItems()

The namespace tree is a recursive data structure—each `NamespaceTreeNode` can contain both child namespaces and operator symbols. Rendering mirrors this recursion.

### Recursive Tree Walking

```csharp
private void DrawNode(NamespaceTreeNode subtree)
{
    if (subtree.Name == NamespaceTreeNode.RootNodeId)
    {
        // [Note: Root node is never drawn; skip directly to children]
        DrawNodeItems(subtree);
    }
    else
    {
        ImGui.PushID(subtree.Name);
        ImGui.SetNextItemWidth(10);

        // [Note: Auto-expand the Lib folder on first display]
        if (subtree.Name == "Lib" && !_openedLibFolderOnce)
        {
            ImGui.SetNextItemOpen(true);
            _openedLibFolderOnce = true;
        }

        var isOpen = ImGui.TreeNode(subtree.Name);

        // [Note: Context menu for renaming]
        CustomComponents.ContextMenuForItem(() =>
        {
            if (ImGui.MenuItem("Rename Namespace"))
            {
                _subtreeNodeToRename = subtree;
                _renameNamespaceDialog.ShowNextFrame();
            }
        });

        if (isOpen)
        {
            HandleDropTarget(subtree);  // [Note: Accept dropped symbols]
            DrawNodeItems(subtree);
            ImGui.TreePop();
        }
        else
        {
            // [Note: Show drop helper button even when closed]
            if (DragAndDropHandling.IsDragging)
            {
                ImGui.SameLine();
                ImGui.PushID("DropButton");
                ImGui.Button("  <-", new Vector2(50, 15));
                HandleDropTarget(subtree);
                ImGui.PopID();
            }
        }

        ImGui.PopID();
    }
}
```

Several design choices stand out:

1. **Root node transparency** — The root is never drawn as a tree node; only its children appear. This avoids a useless "root" label at the top.

2. **Auto-expand Lib** — On first display, the standard library expands automatically. Users want to see operators immediately, not a collapsed tree.

3. **Context menu on namespaces** — Right-clicking a namespace shows a "Rename" option, triggering a modal dialog.

4. **Drop target helper** — When dragging a symbol, closed namespaces show a `<-` button. This solves a UX problem: how do you drop something into a closed folder? The answer is a temporary affordance that appears only during drag operations.

### Rendering Children and Symbols

```csharp
private void DrawNodeItems(NamespaceTreeNode subtree)
{
    // [Note: First draw child namespaces recursively]
    for (var index = 0; index < subtree.Children.Count; index++)
    {
        var subspace = subtree.Children[index];
        DrawNode(subspace);
    }

    // [Note: Then draw symbols at this level, using ToList() for iteration safety]
    for (var index = 0; index < subtree.Symbols.ToList().Count; index++)
    {
        var symbol = subtree.Symbols.ToList()[index];
        DrawSymbolItem(symbol);
    }
}
```

The `ToList()` call on `subtree.Symbols` deserves attention. Why copy the list? Because context menu or drag operations can modify `Symbols`, iterating with `.ToList()` creates a snapshot that remains stable during the loop. Without this, modifying the collection while iterating throws an `InvalidOperationException`.

---

## Search Modes: From Tree to Flat List

When you type in the search box, the tree view vanishes and a flat list appears. This is not just hiding tree nodes—it is a completely different rendering path.

### Flat List Rendering

```csharp
private void DrawFilteredList()
{
    _filter.UpdateIfNecessary(null);
    foreach (var symbolUi in _filter.MatchingSymbolUis)
    {
        DrawSymbolItem(symbolUi.Symbol);
    }
}
```

The `SymbolFilter` class (covered in detail in [Search & Relevance Scoring](../graph/02-search-relevance.md)) handles the heavy lifting: fuzzy matching, relevancy scoring, and result limiting. The library window simply iterates over the pre-sorted results.

### The Question Mark Discovery Feature

Typing `?` activates a "random prompt" mode:

```csharp
else if (_filter.SearchString.Contains('?'))
{
    _randomPromptGenerator.DrawRandomPromptList();
}
```

The `RandomPromptGenerator` counts the question marks and displays that many random operators from the library:

```csharp
var promptCount = filter.SearchString.Count(c => c == '?');
for (uint i = 0; i < promptCount; i++)
{
    var f = MathUtils.Hash01((uint)((i + 42 * _randomSeed * 668265263U) & 0x7fffffff));
    var randomIndex = (int)(f * relevantCount).Clamp(0, relevantCount - 1);
    SymbolLibrary.DrawSymbolItem(filter.MatchingSymbolUis[randomIndex].Symbol);
}
```

The hash function ensures repeatable randomness for a given seed. Users can adjust the seed and a "complexity" slider that limits which operators can appear (filtering out obscure internal helpers).

This feature exists purely for discovery—a way to answer "what interesting operators exist that I do not know about?"

---

## Drag-and-Drop Namespace Reorganization

One of the Symbol Library's most powerful features is drag-and-drop reorganization. Drag any operator onto any namespace, and it moves there. No code edits, no file moves, just instant reorganization.

### Setting Up the Drag Source

When you hover over an operator button and start dragging, `HandleDragAndDropForSymbolItem()` activates:

```csharp
internal static void HandleDragAndDropForSymbolItem(Symbol symbol)
{
    if (IsSymbolCurrentCompositionOrAParent(symbol))
        return;  // [Note: Prevent cycle creation]

    DragAndDropHandling.HandleDragSourceForLastItem(
        DragAndDropHandling.SymbolDraggingId,
        symbol.Id.ToString(),
        "Create instance");

    if (!ImGui.IsItemDeactivated())
        return;

    // [Note: Click (not drag) inserts into graph]
    var wasClick = ImGui.GetMouseDragDelta().Length() < 4;
    if (wasClick)
    {
        var components = ProjectView.Focused;
        if (components == null)
        {
            Log.Error($"No focused graph window found");
        }
        else if (components.NodeSelection.GetSelectedChildUis().Count() == 1)
        {
            ConnectionMaker.InsertSymbolInstance(components, symbol);
        }
    }
}
```

Two behaviors coexist here:

1. **Drag** — Moving the mouse more than 4 pixels initiates a drag operation. The symbol ID becomes the drag payload.

2. **Click** — Releasing without significant movement is treated as a click. If exactly one node is selected in the graph, the clicked operator inserts after it.

The `DragAndDropHandling` helper manages ImGui's drag-drop protocol. It serializes the symbol ID to unmanaged memory (required by ImGui's C interop), tracks the active drag state, and handles cleanup.

### Receiving the Drop

When a dragged symbol hovers over a namespace node, `HandleDropTarget()` checks for drops:

```csharp
private static void HandleDropTarget(NamespaceTreeNode subtree)
{
    if (!DragAndDropHandling.TryGetDataDroppedLastItem(DragAndDropHandling.SymbolDraggingId, out var data))
        return;

    if (!Guid.TryParse(data, out var symbolId))
        return;

    if (!MoveSymbolToNamespace(symbolId, subtree.GetAsString(), out var reason))
        BlockingWindow.Instance.ShowMessageBox(reason, "Could not move symbol's namespace");
}
```

The `TryGetDataDroppedLastItem` method returns true only on the frame when the mouse is released over a valid drop target. The string payload is the symbol GUID serialized earlier.

### Executing the Move

```csharp
private static bool MoveSymbolToNamespace(Guid symbolId, string nameSpace, out string reason)
{
    if (!SymbolUiRegistry.TryGetSymbolUi(symbolId, out var symbolUi))
    {
        reason = $"Could not find symbol with id '{symbolId}'";
        return false;
    }

    if (symbolUi.Symbol.Namespace == nameSpace)
    {
        reason = string.Empty;
        return true;  // [Note: Already there—no-op success]
    }

    if (symbolUi.Symbol.SymbolPackage.IsReadOnly)
    {
        reason = $"Could not move symbol [{symbolUi.Symbol.Name}] because its package is not modifiable";
        return false;
    }

    return EditableSymbolProject.ChangeSymbolNamespace(symbolUi.Symbol, nameSpace, out reason);
}
```

Three validation checks happen:

1. **Symbol exists** — The GUID must resolve to a known symbol.
2. **Not already there** — Moving to the current namespace is a silent success.
3. **Package is editable** — Read-only packages (like the standard library) cannot be modified.

If validation passes, `EditableSymbolProject.ChangeSymbolNamespace()` handles the actual move—updating the symbol's namespace property and persisting the change.

---

## Symbol Item Rendering: The Operator Button

Each operator in the tree or list appears as a colored button with optional badges and context menu. The `DrawSymbolItem()` method handles this complex rendering.

### Type-Colored Buttons

```csharp
internal static void DrawSymbolItem(Symbol symbol)
{
    if (!symbol.TryGetSymbolUi(out var symbolUi))
        return;

    ImGui.PushID(symbol.Id.GetHashCode());
    {
        // [Note: Color based on output type]
        var color = symbol.OutputDefinitions.Count > 0
                        ? TypeUiRegistry.GetPropertiesForType(symbol.OutputDefinitions[0]?.ValueType).Color
                        : UiColors.Gray;

        // [Note: Tag "bookmark" button]
        if (ParameterWindow.DrawSymbolTagsButton(symbolUi))
            symbolUi.FlagAsModified();

        ImGui.SameLine();

        // [Note: The operator button itself]
        ImGui.PushStyleColor(ImGuiCol.Button, ColorVariations.OperatorBackground.Apply(color).Rgba);
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ColorVariations.OperatorBackgroundHover.Apply(color).Rgba);
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, ColorVariations.OperatorBackgroundHover.Apply(color).Rgba);
        ImGui.PushStyleColor(ImGuiCol.Text, ColorVariations.OperatorLabel.Apply(color).Rgba);

        if (ImGui.Button(symbol.Name.AddSpacesForImGuiOutput()))
        {
            // [Note: Click handling happens in HandleDragAndDropForSymbolItem]
        }

        // ... tooltip, context menu, badges ...

        ImGui.PopStyleColor(4);
        HandleDragAndDropForSymbolItem(symbol);
    }
    ImGui.PopID();
}
```

The button color comes from `TypeUiRegistry`, which maps value types to colors. A `Texture2D` output might be blue, a `float` might be green. This visual language carries across the entire editor—operators in the graph use the same colors.

### The Tag Button

Before each operator button, a small icon allows "tagging" the operator:

```csharp
if (ParameterWindow.DrawSymbolTagsButton(symbolUi))
    symbolUi.FlagAsModified();
```

Tags include states like "Obsolete", "NeedsFix", "Favorite". Toggling a tag marks the symbol as modified, ensuring it gets saved.

### Dependency Badges

After the button, small badges show dependency information:

```csharp
if (SymbolAnalysis.DetailsInitialized &&
    SymbolAnalysis.InformationForSymbolIds.TryGetValue(symbol.Id, out var info))
{
    ImGui.PushStyleColor(ImGuiCol.Text, UiColors.TextMuted.Rgba);

    // [Note: "requires..." badge]
    ListSymbolSetWithTooltip(
        250,
        Icon.Dependencies,
        "{0}",
        string.Empty,
        "requires...",
        info.RequiredSymbolIds.ToList());

    // [Note: "invalid references..." badge (attention color)]
    ImGui.PushStyleColor(ImGuiCol.Text, UiColors.StatusAttention.Rgba);
    ListSymbolSetWithTooltip(
        300,
        Icon.None,
        "{0}",
        string.Empty,
        "has invalid references...",
        info.InvalidRequiredIds);
    ImGui.PopStyleColor();

    // [Note: "used by..." badge (clickable!)]
    if (ListSymbolSetWithTooltip(
            340,
            Icon.Referenced,
            "{0}",
            " NOT USED",
            "used by...",
            info.DependingSymbols.ToList()))
    {
        _symbolUsageReferenceFilter = symbol;  // [Note: Switch to usage view]
    }

    ImGui.PopStyleColor();
}
```

Three badge types appear:

| Badge | Meaning | Action |
|-------|---------|--------|
| Dependencies icon + count | "This operator requires N other operators" | Hover for list |
| Count (attention color) | "This operator has N invalid references" | Hover for list |
| Referenced icon + count | "N operators use this one" | **Click to see them** |

The "used by" badge is clickable. Clicking it sets `_symbolUsageReferenceFilter`, which triggers the alternative view mode we saw in `DrawContent()`.

### Context Menu

Right-clicking an operator shows a context menu:

```csharp
CustomComponents.ContextMenuForItem(
    drawMenuItems: () =>
    {
        CustomComponents.DrawSymbolCodeContextMenuItem(symbol);

        ImGui.Separator();

        if (ImGui.MenuItem("Delete Symbol"))
        {
            _symbolToDelete = symbol;
            _deleteSymbolDialog.ShowNextFrame();
        }
    },
    title: symbol.Name,
    id: "##symbolTreeSymbolContextMenu");
```

Two menu items appear:

1. **Edit Code** — Opens the operator's source file in an external editor.
2. **Delete Symbol** — Shows a confirmation dialog, then removes the operator.

---

## Usage Reference View: "What Uses This?"

When you click the "used by" badge, the entire window transforms:

```csharp
private static void DrawUsagesAReferencedSymbol()
{
    if (_symbolUsageReferenceFilter == null)
        return;

    ImGui.Text("Usages of " + _symbolUsageReferenceFilter.Name + ":");
    if (ImGui.Button("Clear"))
    {
        _symbolUsageReferenceFilter = null;
    }
    else
    {
        ImGui.Separator();

        ImGui.BeginChild("scrolling");
        {
            if (SymbolAnalysis.DetailsInitialized &&
                SymbolAnalysis.InformationForSymbolIds.TryGetValue(_symbolUsageReferenceFilter.Id, out var info))
            {
                var allSymbols = EditorSymbolPackage.AllSymbols.ToDictionary(s => s.Id);

                foreach (var id in info.DependingSymbols)
                {
                    if (allSymbols.TryGetValue(id, out var symbol))
                    {
                        DrawSymbolItem(symbol);
                    }
                }
            }
        }
        ImGui.EndChild();
    }
}
```

The view shows:

1. **Header** — "Usages of [SymbolName]:"
2. **Clear button** — Returns to normal tree view
3. **List** — All operators that reference the selected symbol

This is invaluable for refactoring. Before modifying or deleting an operator, you can see exactly what depends on it.

---

## Code Trace: Opening the Library and Searching

Let us walk through a complete user interaction.

### Scene: Finding a Blur Operator

```
1. User opens Symbol Library window
   ↓
   SymbolLibrary constructor runs:
   - _filter.SearchString = ""
   - _treeNode.PopulateCompleteTree()  // Builds namespace hierarchy
   - _libraryFiltering = new LibraryFiltering(this)

2. First frame renders
   ↓
   DrawContent() → DrawView()
   - Search string is empty → DrawNode(_treeNode)
   - "Lib" auto-expands (first display)
   - User sees tree structure

3. User types "blur" in search box
   ↓
   _filter.SearchString = "blur"
   DrawView() detects non-empty search string
   → DrawFilteredList()
   - _filter.UpdateIfNecessary(null)
       → Regex pattern: "b.*l.*u.*r"
       → Iterates all symbols
       → Fuzzy matches + relevancy scoring
       → Returns top 100 sorted results
   - Loops over _filter.MatchingSymbolUis
   - Renders each as DrawSymbolItem()

4. User sees flat list:
   - [Blur] (from Lib.Image.Filter)
   - [DirectionalBlur]
   - [RadialBlur]
   - [CustomBlur] (from MyProject)
   - ...

5. User clears search (backspace)
   ↓
   _filter.SearchString = ""
   DrawView() → DrawNode(_treeNode)
   Tree view returns
```

### Scene: Reorganizing with Drag-Drop

```
1. User locates "CustomBlur" in MyProject namespace
   ↓

2. User clicks and drags the button
   ↓
   HandleDragAndDropForSymbolItem() activates:
   - Mouse delta > 4px → drag initiated
   - DragAndDropHandling.HandleDragSourceForLastItem()
       → Payload: CustomBlur's GUID
       → ImGui drag-drop source started

3. User drags over "Lib.Image.Filter" namespace
   ↓
   DrawNode() for Lib.Image.Filter:
   - Node is open → HandleDropTarget(subtree)
   - Item is hovered → orange highlight

4. User releases mouse
   ↓
   HandleDropTarget():
   - TryGetDataDroppedLastItem() returns true
   - Parses GUID from payload
   - MoveSymbolToNamespace(customBlurId, "Lib.Image.Filter", ...)
       → Validates symbol exists ✓
       → Validates not read-only ✓
       → EditableSymbolProject.ChangeSymbolNamespace()

5. Next frame:
   ↓
   - CustomBlur now appears under Lib.Image.Filter
   - MyProject namespace no longer contains it
```

---

## Quality Filters: Finding Problems

After pressing the Refresh button, quality filters become available. The `LibraryFiltering` class draws checkbox toggles. The following is a simplified illustration of the filter logic (the actual implementation differs in structure):

```csharp
// [Note: Simplified illustration—actual implementation differs]
internal void DrawSymbolFilters()
{
    ImGui.SameLine();
    var status = _showFilters ? CustomComponents.ButtonStates.Activated : CustomComponents.ButtonStates.Dimmed;

    if (CustomComponents.IconButton(Icon.Flame, Vector2.Zero, status))
        _showFilters = !_showFilters;

    if (!_showFilters)
        return;

    // Draw filter checkboxes
    needsUpdate |= DrawFilterToggle("Help missing ({0})", count, Flags.MissingDescriptions, ref _activeFilters);
    needsUpdate |= DrawFilterToggle("Unused ({0})", count, Flags.Unused, ref _activeFilters);
    needsUpdate |= DrawFilterToggle("Invalid Op dependencies ({0})", count, Flags.InvalidRequiredOps, ref _activeFilters);
    // ... more filters ...

    if (needsUpdate)
    {
        _symbolLibrary.FilteredTree.PopulateCompleteTree(s =>
        {
            // Predicate filters symbols
            return _activeFilters.HasFlag(Flags.MissingDescriptions) && info.LacksDescription
                || _activeFilters.HasFlag(Flags.Unused) && info.DependingSymbols.Count == 0
                // ... etc ...
        });
    }
}
```

Each filter flag represents a criterion:

| Filter | Shows Operators That... |
|--------|------------------------|
| Help missing | Have no description |
| Parameter help missing | Have undocumented parameters |
| No grouping | Have ungrouped parameters |
| Unused | Are never referenced |
| Invalid dependencies | Reference non-existent operators |
| Depends on obsolete | Use deprecated operators |
| Obsolete | Are marked deprecated |
| NeedsFix | Are flagged for repair |

When filters are active, `DrawView()` renders `FilteredTree` instead of the normal `_treeNode`. The filtered tree is rebuilt each time the filter selection changes.

---

## Key Source Files

| File | Approx. LOC | Purpose |
|------|-------------|---------|
| `Editor/Gui/Windows/SymbolLib/SymbolLibrary.cs` | ~580 | Main window class, rendering, drag-drop |
| `Editor/Gui/Windows/SymbolLib/NamespaceTreeNode.cs` | ~130 | Recursive tree data structure |
| `Editor/Gui/Windows/SymbolLib/LibraryFiltering.cs` | ~230 | Quality filter checkboxes |
| `Editor/Gui/Windows/SymbolLib/RandomPromptGenerator.cs` | ~70 | The `?` discovery feature |
| `Editor/Gui/UiHelpers/DragAndDropHandling.cs` | ~130 | ImGui drag-drop protocol wrapper |
| `Editor/UiModel/Helpers/SymbolFilter.cs` | ~390 | Search algorithm and relevancy |

---

## Design Insights

### Why a Docked Window Instead of Just the Popup?

The Symbol Browser popup (Tab key) is optimized for **insertion**—finding an operator to add to your graph. But discovery is different. Sometimes you want to:

- Browse without inserting
- See what is deprecated
- Find operators missing documentation
- Reorganize namespace structure

A persistent window supports these workflows. You can leave it open while working, glancing at it occasionally.

### Why Separate Tree and List Views?

The tree view preserves hierarchy—operators grouped by namespace help you understand organizational structure. But hierarchy is the enemy of search. When you know (partially) what you want, flattening the view eliminates navigation friction.

The "?" feature is pure serendipity. It solves a problem that search cannot: "show me something I do not know to search for."

### Why Drag-Drop for Namespace Changes?

Namespace reorganization happens frequently during development. Making it require code edits (changing the `Namespace` attribute in source) adds friction. Drag-drop makes it feel like file management—intuitive and instant.

The read-only check prevents accidents: you cannot reorganize the standard library, only your own code.

---

## Edge Cases and Gotchas

### Modifying the Tree During Iteration

```csharp
for (var index = 0; index < subtree.Symbols.ToList().Count; index++)
```

The `.ToList()` creates a copy. Because context menu or drag operations can modify `Symbols`, iterating with `.ToList()` creates a snapshot that remains stable during the loop. Without the copy, you get `InvalidOperationException: Collection was modified`.

### Drop Target on Closed Nodes

When dragging, closed namespace nodes show a `<-` button:

```csharp
if (DragAndDropHandling.IsDragging)
{
    ImGui.SameLine();
    ImGui.Button("  <-", new Vector2(50, 15));
    HandleDropTarget(subtree);
}
```

This button only appears during drag operations. It solves the "how do I drop into a closed folder?" problem without requiring manual tree expansion.

### The Root Node is Invisible

```csharp
if (subtree.Name == NamespaceTreeNode.RootNodeId)
{
    DrawNodeItems(subtree);  // [Note: Skip drawing node, just draw children]
}
```

The root node exists in the data structure but never renders. Top-level namespaces (Lib, Types, Examples) appear as the first visible level.

---

## Summary

The Symbol Library window solves operator discovery and organization:

- **Hierarchical tree** — Browse namespaces like folders
- **Search flattening** — Type to filter; tree becomes list
- **Question mark discovery** — Random suggestions for exploration
- **Drag-and-drop reorganization** — Instant namespace changes
- **Quality filters** — Find operators needing attention
- **Usage reference view** — See what depends on any operator

Unlike the context-sensitive Symbol Browser popup, the Symbol Library is persistent and exploratory. It is where you go when you do not know exactly what you are looking for—or when you want to clean up the mess you made last week.

---

**Previous:** [Index](00-index.md) | **Next:** [Namespace Tree & Filtering](02-namespace-tree.md)
