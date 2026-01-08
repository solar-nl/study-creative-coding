# Chapter 11: Operator Browser - Creating New Operators

> *Type, search, select - adding nodes without memorizing the symbol tree*

---

## The User's Need: Fast Node Creation

You're building a composition. You need a `Multiply` operator. How do you add it?

**The slow way:** Right-click, navigate through menus: Math → Operators → Multiply. Twenty seconds.

**The fast way:** Press Tab, type "mul", hit Enter. Two seconds.

The operator browser (internally called "Placeholder") makes the fast way possible. It's:

- A **search interface** - type partial names, get instant matches
- A **tree browser** - navigate the symbol hierarchy when exploring
- A **preview system** - see what will be connected before you commit
- A **temporary canvas item** - shows where the new node will appear

When you drag a connection and drop it on empty space, the browser opens automatically, filtered to compatible types. This flow - drag output, release, type name, Enter - becomes second nature.

**Key Source Files:**

- [PlaceholderCreation.cs](../../../Editor/Gui/MagGraph/Interaction/PlaceholderCreation.cs) (~400 lines)
- [PlaceHolderUi.cs](../../../Editor/Gui/MagGraph/Interaction/PlaceHolderUi.cs) (~600 lines)
- [SymbolBrowsing.cs](../../../Editor/Gui/MagGraph/Interaction/SymbolBrowsing.cs) (~300 lines)

---

## Browser Triggers

The operator browser can be opened in several ways:

### 1. Tab Key (Keyboard Shortcut)

```csharp
// In GraphStates.Default:
if (ImGui.IsKeyReleased(ImGuiKey.Tab))
{
    var focusedObject = context.Selector.Selection.Count == 1
        && context.View.IsItemVisible(context.Selector.Selection[0])
            ? context.Selector.Selection[0]
            : null;

    if (focusedObject != null
        && context.Layout.Items.TryGetValue(focusedObject.Id, out var focusedItem))
    {
        // Open connected to selection's output
        context.Placeholder.OpenForItemOutput(context, focusedItem, focusedItem.OutputLines[0]);
    }
    else
    {
        // Open at mouse position
        var posOnCanvas = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
        context.Placeholder.OpenOnCanvas(context, posOnCanvas);
    }
    context.StateMachine.SetState(Placeholder, context);
}
```

### 2. Long Press on Background

```csharp
// In GraphStates.HoldBackground:
const float longTapDuration = 0.3f;
var longTapProgress = context.StateMachine.StateTime / longTapDuration;

if (longTapProgress > 1)
{
    context.StateMachine.SetState(Placeholder, context);
    var posOnCanvas = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
    context.Placeholder.OpenOnCanvas(context, posOnCanvas);
}
```

### 3. Click on Output Anchor

```csharp
// In GraphStates.HoldOutput - on mouse release:
if (context.TryGetActiveOutputLine(out var outputLine))
{
    context.Placeholder.OpenForItemOutput(context, sourceItem, outputLine, context.ActiveOutputDirection);
    context.StateMachine.SetState(Placeholder, context);
}
```

### 4. Click on Input Anchor

```csharp
// In GraphStates.HoldInput - on mouse release:
if (context.TryGetActiveInputLine(out var inputLine))
{
    context.Placeholder.OpenForItemInput(context, context.ActiveTargetItem, inputLine.Id, context.ActiveInputDirection);
    context.StateMachine.SetState(Placeholder, context);
}
```

### 5. Drag Connection to Empty Space

```csharp
// In GraphStates.DragConnectionEnd:
context.Placeholder.OpenOnCanvas(context, posOnCanvas, context.DraggedPrimaryOutputType);
context.StateMachine.SetState(Placeholder, context);
```

### 6. Click on Connection Line (Insert)

```csharp
// In GraphStates.HoldingConnectionEnd/Beginning:
context.Placeholder.OpenToSplitHoveredConnections(context);
```

---

## PlaceholderCreation Class

This class manages the placeholder lifecycle:

```csharp
internal sealed class PlaceholderCreation
{
    internal MagGraphItem? PlaceholderItem { get; private set; }
    internal MagGraphItem? SourceItem { get; private set; }
    internal MagGraphItem? TargetItem { get; private set; }
    internal Type? ConnectionType { get; private set; }

    internal void OpenOnCanvas(GraphUiContext context, Vector2 position, Type? filterType = null)
    {
        // Create placeholder item
        PlaceholderItem = new MagGraphItem
        {
            Id = PlaceHolderId,
            Variant = MagGraphItem.Variants.Placeholder,
            Selectable = new PlaceholderSelectable { PosOnCanvas = position },
            Size = MagGraphItem.GridSize,
            DampedPosOnCanvas = position,
        };

        context.Layout.Items[PlaceHolderId] = PlaceholderItem;
        ConnectionType = filterType;
        SourceItem = null;
        TargetItem = null;

        _searchFilter.Reset();
        if (filterType != null)
        {
            _searchFilter.SetTypeFilter(filterType);
        }
    }

    internal void OpenForItemOutput(GraphUiContext context, MagGraphItem sourceItem,
        MagGraphItem.OutputLine outputLine, MagGraphItem.Directions direction = Directions.Horizontal)
    {
        var position = direction == Directions.Horizontal
            ? sourceItem.PosOnCanvas + new Vector2(MagGraphItem.Width + MagGraphItem.Width, 0)
            : sourceItem.PosOnCanvas + new Vector2(0, sourceItem.Size.Y + MagGraphItem.LineHeight);

        OpenOnCanvas(context, position, outputLine.Output.ValueType);
        SourceItem = sourceItem;
        _sourceOutputId = outputLine.Id;
        _connectionDirection = direction;
    }

    internal void OpenForItemInput(GraphUiContext context, MagGraphItem targetItem,
        Guid inputId, MagGraphItem.Directions direction)
    {
        // Similar to OpenForItemOutput but positions before the target
    }

    internal void Cancel(GraphUiContext context)
    {
        if (PlaceholderItem != null)
        {
            context.Layout.Items.Remove(PlaceHolderId);
            PlaceholderItem = null;
        }
        _searchFilter.Reset();
    }

    internal void Reset(GraphUiContext context)
    {
        Cancel(context);
        SourceItem = null;
        TargetItem = null;
        ConnectionType = null;
    }
}
```

---

## PlaceHolderUi - The Browser Interface

The `PlaceHolderUi` class handles the actual UI drawing:

```csharp
internal static class PlaceHolderUi
{
    internal static void Draw(GraphUiContext context)
    {
        var placeholder = context.Placeholder;
        if (placeholder.PlaceholderItem == null)
            return;

        var placeholderPos = context.View.TransformPosition(placeholder.PlaceholderItem.PosOnCanvas);

        // Draw the placeholder box
        DrawPlaceholderBox(context, placeholderPos);

        // Draw the search popup
        ImGui.SetNextWindowPos(placeholderPos + new Vector2(MagGraphItem.Width + 10, 0));
        ImGui.SetNextWindowSize(new Vector2(300, 400));

        if (ImGui.Begin("##OperatorBrowser", ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize))
        {
            // Search input
            ImGui.SetKeyboardFocusHere();
            if (ImGui.InputText("##Search", ref _searchText, 256))
            {
                UpdateSearchResults(context);
            }

            // Results list
            if (ImGui.BeginChild("##Results"))
            {
                foreach (var result in _filteredSymbols)
                {
                    var isSelected = result == _selectedSymbol;
                    if (ImGui.Selectable(result.Name, isSelected))
                    {
                        CreateOperator(context, result);
                    }
                }
                ImGui.EndChild();
            }

            ImGui.End();
        }

        // Handle keyboard navigation
        HandleKeyboardInput(context);
    }

    private static void HandleKeyboardInput(GraphUiContext context)
    {
        if (ImGui.IsKeyPressed(ImGuiKey.DownArrow))
        {
            _selectedIndex = Math.Min(_selectedIndex + 1, _filteredSymbols.Count - 1);
        }
        else if (ImGui.IsKeyPressed(ImGuiKey.UpArrow))
        {
            _selectedIndex = Math.Max(_selectedIndex - 1, 0);
        }
        else if (ImGui.IsKeyPressed(ImGuiKey.Enter))
        {
            if (_selectedSymbol != null)
            {
                CreateOperator(context, _selectedSymbol);
            }
        }
        else if (ImGui.IsKeyPressed(ImGuiKey.Escape))
        {
            context.Placeholder.Cancel(context);
            context.StateMachine.SetState(GraphStates.Default, context);
        }
    }
}
```

---

## SymbolBrowsing - The Tree Navigator

`SymbolBrowsing` provides hierarchical navigation through namespaces:

```csharp
internal static class SymbolBrowsing
{
    internal static void DrawSymbolTree(GraphUiContext context, Type? typeFilter)
    {
        var rootNodes = BuildNamespaceTree(typeFilter);

        foreach (var node in rootNodes)
        {
            DrawNamespaceNode(context, node);
        }
    }

    private static void DrawNamespaceNode(GraphUiContext context, NamespaceNode node)
    {
        var flags = node.HasChildren
            ? ImGuiTreeNodeFlags.None
            : ImGuiTreeNodeFlags.Leaf;

        if (ImGui.TreeNodeEx(node.Name, flags))
        {
            // Draw child namespaces
            foreach (var child in node.Children)
            {
                DrawNamespaceNode(context, child);
            }

            // Draw symbols in this namespace
            foreach (var symbol in node.Symbols)
            {
                if (ImGui.Selectable(symbol.Name))
                {
                    CreateOperator(context, symbol);
                }

                // Tooltip with description
                if (ImGui.IsItemHovered() && !string.IsNullOrEmpty(symbol.Description))
                {
                    ImGui.SetTooltip(symbol.Description);
                }
            }

            ImGui.TreePop();
        }
    }

    private static List<NamespaceNode> BuildNamespaceTree(Type? typeFilter)
    {
        var symbols = SymbolRegistry.Entries.Values
            .Where(s => !s.IsObsolete)
            .Where(s => typeFilter == null || HasMatchingOutput(s, typeFilter))
            .OrderBy(s => s.Namespace)
            .ThenBy(s => s.Name);

        // Build tree structure from dot-separated namespaces
        var root = new Dictionary<string, NamespaceNode>();

        foreach (var symbol in symbols)
        {
            AddToTree(root, symbol);
        }

        return root.Values.ToList();
    }
}
```

---

## Type Filtering

When opening with a type filter, only compatible symbols are shown:

```csharp
internal static bool HasMatchingOutput(Symbol symbol, Type requiredOutputType)
{
    foreach (var output in symbol.OutputDefinitions)
    {
        if (output.ValueType == requiredOutputType)
            return true;

        // Check for polymorphic compatibility
        if (requiredOutputType.IsAssignableFrom(output.ValueType))
            return true;
    }

    return false;
}

internal static bool HasMatchingInput(Symbol symbol, Type requiredInputType)
{
    foreach (var input in symbol.InputDefinitions)
    {
        if (input.DefaultValue.ValueType == requiredInputType)
            return true;

        if (requiredInputType.IsAssignableFrom(input.DefaultValue.ValueType))
            return true;
    }

    return false;
}
```

---

## Creating the Operator

When a symbol is selected, the operator is created:

```csharp
private static void CreateOperator(GraphUiContext context, Symbol symbol)
{
    var placeholder = context.Placeholder;
    var position = placeholder.PlaceholderItem.PosOnCanvas;

    // Create the operator
    var macroCommand = context.StartMacroCommand("Create Operator");

    var addSymbolChild = new AddSymbolChildCommand(
        context.CompositionInstance.Symbol,
        symbol.Id,
        position
    );
    macroCommand.AddAndExecCommand(addSymbolChild);

    var newChildId = addSymbolChild.AddedChildId;

    // Create connection from source if available
    if (placeholder.SourceItem != null && placeholder._sourceOutputId != Guid.Empty)
    {
        // Find matching input on new operator
        var matchingInput = FindMatchingInput(symbol, placeholder.ConnectionType);
        if (matchingInput != null)
        {
            var newConnection = new Symbol.Connection(
                placeholder.SourceItem.Id,
                placeholder._sourceOutputId,
                newChildId,
                matchingInput.Id
            );

            macroCommand.AddAndExecCommand(
                new AddConnectionCommand(context.CompositionInstance.Symbol, newConnection, 0)
            );
        }
    }

    // Create connection to target if available
    if (placeholder.TargetItem != null && placeholder._targetInputId != Guid.Empty)
    {
        // Similar logic for connecting to target
    }

    context.CompleteMacroCommand();
    context.Layout.FlagStructureAsChanged();
    placeholder.Reset(context);
    context.StateMachine.SetState(GraphStates.Default, context);

    // Select the new operator
    if (context.Layout.Items.TryGetValue(newChildId, out var newItem))
    {
        newItem.Select(context.Selector);
    }
}
```

---

## Splitting Connections

When clicking on a connection line, the placeholder opens for insertion:

```csharp
internal void OpenToSplitHoveredConnections(GraphUiContext context)
{
    if (context.ConnectionHovering.ConnectionHoversWhenClicked.Count == 0)
    {
        context.StateMachine.SetState(GraphStates.Default, context);
        return;
    }

    var hover = context.ConnectionHovering.ConnectionHoversWhenClicked[0];
    var connection = hover.Connection;

    // Position between source and target
    var midPoint = (connection.SourcePos + connection.TargetPos) / 2;

    OpenOnCanvas(context, midPoint, connection.Type);

    // Store connection for split
    _connectionToSplit = connection;
    SourceItem = connection.SourceItem;
    _sourceOutputId = connection.SourceOutput.Id;
    TargetItem = connection.TargetItem;
    _targetInputId = connection.TargetInput.Id;

    context.StateMachine.SetState(GraphStates.Placeholder, context);
}
```

---

## Search Algorithm

The search uses fuzzy matching:

```csharp
internal static float GetMatchScore(string symbolName, string searchText)
{
    if (string.IsNullOrEmpty(searchText))
        return 1f;

    var searchLower = searchText.ToLower();
    var nameLower = symbolName.ToLower();

    // Exact match
    if (nameLower == searchLower)
        return 100f;

    // Starts with search text
    if (nameLower.StartsWith(searchLower))
        return 90f + (searchLower.Length / (float)nameLower.Length);

    // Contains search text
    if (nameLower.Contains(searchLower))
        return 50f + (searchLower.Length / (float)nameLower.Length);

    // Character sequence match (fuzzy)
    var sequenceScore = GetSequenceMatchScore(nameLower, searchLower);
    if (sequenceScore > 0)
        return sequenceScore;

    return 0f;
}

private static float GetSequenceMatchScore(string name, string search)
{
    var nameIndex = 0;
    var matchCount = 0;

    foreach (var searchChar in search)
    {
        while (nameIndex < name.Length)
        {
            if (name[nameIndex] == searchChar)
            {
                matchCount++;
                nameIndex++;
                break;
            }
            nameIndex++;
        }
    }

    if (matchCount == search.Length)
    {
        return 20f + (matchCount / (float)name.Length) * 20f;
    }

    return 0f;
}
```

---

## Visual Feedback

The placeholder provides visual feedback:

1. **Placeholder box** - Shows where the operator will be created
2. **Connection preview** - Dashed line showing what will be connected
3. **Type indicator** - Color showing the expected type
4. **Search results** - Highlighted matches in search

---

## Next Steps

- **[Interaction Annotations](12-interaction-annotations.md)** - Frame manipulation
- **[Rendering Nodes](15-rendering-nodes.md)** - How placeholders are drawn
- **[State Machine](07-state-machine.md)** - Placeholder state transitions
