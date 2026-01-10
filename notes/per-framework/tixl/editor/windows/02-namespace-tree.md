# Chapter 2: Namespace Tree and Filtering

> *A thousand operators, organized in milliseconds—the tree builds itself by parsing namespaces and respecting a deliberate ordering.*

## Key Insight

> **Namespace tree's core idea:** Flat namespace strings like "Lib.Image.Filter" are parsed into a recursive tree structure at startup, with priority ordering (Lib first, then Types, then user code) and predicate filtering for building sparse trees matching quality criteria.

**Previous:** [Symbol Library Window](01-symbol-library.md) | **Next:** [Search & Relevance](../graph/02-search-relevance.md)

---

## The Problem: Turning Flat Strings into Hierarchy

Imagine you have 500 operators. Each has a namespace string like `"Lib.3d.mesh.Generate"` or `"Types.Color.Conversion"`. Internally, these are just strings—there is no built-in parent/child relationship. How do you display them as a browsable tree?

The naive approach is to store operators in a flat list and compute the tree structure on every render. Parse the namespace, split by `.`, walk the existing tree, create missing nodes, insert the symbol. This works, but becomes expensive at scale—500 operators means 500 string splits and tree traversals every frame.

The better approach: **build the tree once, then just render it**. The `NamespaceTreeNode` class does exactly this. It transforms flat namespace strings into a recursive tree structure that can be traversed and rendered efficiently.

---

## The Mental Model: File System from Paths

Think of namespace strings like file paths without slashes:

```
Lib.3d.mesh.Generate     →  /Lib/3d/mesh/Generate
Types.Color.Conversion   →  /Types/Color/Conversion
Examples.Audio.Analyzer  →  /Examples/Audio/Analyzer
```

Just as a file system creates intermediate directories (`mkdir -p`), the tree builder creates intermediate namespace nodes. The namespace `Lib.3d.mesh.Generate` produces four nodes: `Lib`, `3d`, `mesh`, and `Generate`—each nested inside the previous.

The key insight is that multiple operators can share intermediate nodes. `Lib.3d.mesh.Generate` and `Lib.3d.mesh.Combine` both live under the same `Lib.3d.mesh` parent. The tree builder must detect existing nodes and reuse them rather than creating duplicates.

---

## The NamespaceTreeNode Structure

Each node in the tree holds four pieces of information:

```csharp
internal sealed class NamespaceTreeNode
{
    internal string Name { get; private set; }          // This node's name segment
    internal List<NamespaceTreeNode> Children { get; }  // Child namespace nodes
    private NamespaceTreeNode? Parent { get; }          // Link back to parent
    internal readonly List<Symbol> Symbols = [];        // Operators at this level
}
```

Let us trace a concrete example. For the namespace `Lib.Image.Filter` containing two operators (`Blur` and `Sharpen`), the tree looks like:

```
root (Name="root", Symbols=[])
  └── Lib (Name="Lib", Symbols=[])
        └── Image (Name="Image", Symbols=[])
              └── Filter (Name="Filter", Symbols=[Blur, Sharpen])
```

Each node knows its name, its children, and its parent. The `Symbols` list holds operators that belong directly at this namespace level—operators whose namespace exactly matches this node's full path.

### Reconstructing the Full Path

Given a node deep in the tree, how do you get its full namespace string? The `GetAsString()` method walks up the parent chain:

```csharp
internal string GetAsString()
{
    var list = new List<string>();
    var t = this;
    while (t.Parent != null)
    {
        list.Insert(0, t.Name);  // [Note: Prepend, so order is correct]
        t = t.Parent;
    }
    return string.Join(".", list);
}
```

Starting from the `Filter` node:
1. Add "Filter" to list → `["Filter"]`
2. Move to parent (Image), add "Image" → `["Image", "Filter"]`
3. Move to parent (Lib), add "Lib" → `["Lib", "Image", "Filter"]`
4. Move to parent (root), parent is null → stop
5. Join with "." → `"Lib.Image.Filter"`

The root node is excluded because it is just a container—it has no meaningful name in the namespace hierarchy.

---

## Tree Population: Building the Hierarchy

The `PopulateCompleteTree()` method is the entry point. It takes all operators in the system and organizes them into the tree structure.

### Step 1: Clear and Prepare

```csharp
internal void PopulateCompleteTree(Predicate<SymbolUi>? filterAction)
{
    Name = RootNodeId;  // "root"
    Clear();            // Empty the tree

    // ... sorting and iteration follows
}
```

The tree starts fresh each time. This prevents stale data—if an operator was deleted or renamed, the new tree reflects reality.

### Step 2: Sort Operators with Root Priority

Before inserting operators, the method sorts them with a deliberate ordering:

```csharp
var ordered = EditorSymbolPackage.AllSymbolUis
    .OrderBy(ui =>
    {
        var ns = ui.Symbol.Namespace ?? string.Empty;

        // Find matching root index
        var index = _rootProjectNames.FindIndex(p => ns.StartsWith(p, StringComparison.Ordinal));
        if (index < 0)
            index = int.MaxValue;

        return (index, ns + ui.Symbol.Name);
    });
```

The `_rootProjectNames` list defines a priority ordering:

```csharp
private static readonly List<string> _rootProjectNames = [
    "Lib.",
    "Types.",
    "Examples.",
    "t3.",
];
```

This means:
- Operators under `Lib.*` appear first
- Then `Types.*`
- Then `Examples.*`
- Then `t3.*`
- Everything else comes last (`int.MaxValue`)

Within each priority tier, operators are sorted alphabetically by namespace + name. The result: when you browse the tree, the standard library appears at the top, followed by types, examples, internal framework code, and finally user projects.

Why sort before inserting? Because tree traversal during insertion benefits from locality. If you insert `Lib.Image.Blur` followed by `Lib.Image.Sharpen`, the second insertion reuses the path traversed by the first. Random insertion order would cause more node lookups.

### Step 3: Insert Each Operator

```csharp
foreach (var ui in ordered)
{
    var keep = filterAction == null || filterAction(ui);
    if (!keep)
        continue;

    SortInOperator(ui.Symbol);
}
```

The optional `filterAction` predicate enables filtered tree views (more on this later). If no filter is provided, all operators are inserted.

---

## The Insertion Algorithm: SortInOperator()

This is the heart of tree construction. Given an operator with namespace `Lib.Image.Filter`, it ensures all intermediate nodes exist and places the operator in the correct leaf.

```csharp
private void SortInOperator(Symbol symbol)
{
    if (symbol.Namespace == null)
        return;  // [Note: Operators without namespace are skipped]

    var spaces = symbol.Namespace.Split('.');

    var currentNode = this;
    var expandingSubTree = false;

    foreach (var spaceName in spaces)
    {
        if (spaceName == "")
            continue;  // [Note: Handle empty segments from trailing dots]

        if (!expandingSubTree)
        {
            if (currentNode.TryFindNodeDataByName(spaceName, out var node))
            {
                currentNode = node;  // [Note: Node exists, reuse it]
            }
            else
            {
                expandingSubTree = true;  // [Note: From here, create new nodes]
            }
        }

        if (!expandingSubTree)
            continue;

        var newNode = new NamespaceTreeNode(spaceName, currentNode);
        currentNode.Children.Add(newNode);
        currentNode = newNode;
    }

    currentNode.Symbols.Add(symbol);
}
```

Let us trace this for namespace `"Lib.Image.Filter"`:

**Initial state:** Tree already has `Lib` and `Lib.Image` from previous insertions.

1. Split `"Lib.Image.Filter"` → `["Lib", "Image", "Filter"]`
2. Start at root, `expandingSubTree = false`

3. Process "Lib":
   - `TryFindNodeDataByName("Lib")` → found!
   - `currentNode = Lib`
   - Still not expanding

4. Process "Image":
   - `TryFindNodeDataByName("Image")` → found!
   - `currentNode = Image`
   - Still not expanding

5. Process "Filter":
   - `TryFindNodeDataByName("Filter")` → not found
   - `expandingSubTree = true`
   - Create new node: `Filter` with parent `Image`
   - Add to `Image.Children`
   - `currentNode = Filter`

6. Loop ends, add symbol to `Filter.Symbols`

The `expandingSubTree` flag is an optimization. Once you find a missing node, all subsequent nodes in the path must also be missing. The algorithm switches from "search and reuse" to "create unconditionally", skipping unnecessary lookups.

### Node Lookup

The `TryFindNodeDataByName` method performs a simple linear search through children:

```csharp
private bool TryFindNodeDataByName(string name, [NotNullWhen(true)] out NamespaceTreeNode? node)
{
    node = Children.FirstOrDefault(n => n.Name == name);
    return node != null;
}
```

Linear search might seem inefficient, but in practice the number of children at any level is small—typically 5-20. A hash lookup would add overhead for this scale.

---

## Predicate Filtering: Building Partial Trees

Sometimes you want a tree containing only operators that match certain criteria—those missing documentation, for example. The `filterAction` parameter enables this:

```csharp
internal void PopulateCompleteTree(Predicate<SymbolUi>? filterAction)
{
    // ...
    foreach (var ui in ordered)
    {
        var keep = filterAction == null || filterAction(ui);
        if (!keep)
            continue;

        SortInOperator(ui.Symbol);
    }
}
```

The predicate receives a `SymbolUi` and returns true to include, false to exclude. This happens before insertion, so excluded operators never create tree nodes. The result is a sparse tree containing only matching operators.

For example, to build a tree of operators missing descriptions:

```csharp
tree.PopulateCompleteTree(symbolUi =>
{
    if (!SymbolAnalysis.TryGetSymbolInfo(symbolUi.Symbol, out var info))
        return false;

    return info.LacksDescription;
});
```

Note that the predicate receives the full `SymbolUi` wrapper, giving you access to both UI metadata and the underlying `Symbol` via `symbolUi.Symbol`.

---

## The LibraryFiltering System

The `LibraryFiltering` class provides the UI for quality-based filtering. It maintains a set of toggleable filter flags and rebuilds the filtered tree when selections change.

### Filter Flags as a Bitmask

```csharp
[Flags]
private enum Flags
{
    None = 0,
    MissingDescriptions = 1 << 1,
    MissingAllParameterDescriptions = 1 << 2,
    MissingSomeParameterDescriptions = 1 << 3,
    MissingParameterGrouping = 1 << 4,
    InvalidRequiredOps = 1 << 5,
    Unused = 1 << 6,
    Obsolete = 1 << 7,
    NeedsFix = 1 << 8,
    DependsOnObsoleteOps = 1 << 9,
}
```

Each filter is a bit position. The `_activeFilters` field stores the combined selection. Toggling a filter XORs its bit:

```csharp
if (clicked)
{
    activeFlags ^= filterFlag;
}
```

This allows multiple filters to be active simultaneously—"show me operators that are both unused AND missing documentation."

### Drawing Filter Toggles

The `DrawSymbolFilters()` method renders checkboxes for each filter:

```csharp
needsUpdate |= DrawFilterToggle(
    "Help missing ({0})",
    opInfos.Count(i => i.LacksDescription && ...),
    Flags.MissingDescriptions,
    ref _activeFilters);
```

Each toggle displays:
- A label with placeholder for count: `"Help missing ({0})"`
- The count of matching operators (dynamically computed)
- Which flag it controls
- Reference to the active flags bitmask

The `{0}` in the label gets filled with the count, so users see "Help missing (47)" rather than just "Help missing".

### Rebuilding the Filtered Tree

When any filter changes, the filtered tree is rebuilt:

```csharp
if (needsUpdate)
{
    _symbolLibrary.FilteredTree.PopulateCompleteTree(s =>
    {
        if (!SymbolAnalysis.TryGetSymbolInfo(s.Symbol, out var info))
            return false;

        if (_onlyInLib && info.OperatorType != SymbolAnalysis.OperatorClassification.Lib)
            return false;

        if (!AnyFilterActive)
            return true;

        return
            _activeFilters.HasFlag(Flags.MissingDescriptions) && info.LacksDescription
            || _activeFilters.HasFlag(Flags.MissingAllParameterDescriptions) && info.LacksAllParameterDescription
            || _activeFilters.HasFlag(Flags.Unused) && info.DependingSymbols.Count == 0
            // ... more filter conditions ...
    });
}
```

The predicate checks:
1. Does analysis data exist for this symbol?
2. If "Only in Lib" is checked, is this a library operator?
3. If no filters active, include everything
4. Otherwise, include if ANY active filter matches

The result is an OR combination: "missing description OR unused OR obsolete." If you want AND semantics, you would need to change `||` to `&&`.

### The Scan Gate

Filters only appear after the user presses the Refresh button:

```csharp
if (_wasScanned)
{
    _libraryFiltering.DrawSymbolFilters();
}
```

Why delay? The `SymbolAnalysis` system that computes dependency information is expensive. Running it on every startup would slow down the editor. Instead, users opt-in by clicking Refresh, which triggers:

```csharp
if (CustomComponents.IconButton(Icon.Refresh, ...))
{
    _treeNode.PopulateCompleteTree();
    ExampleSymbolLinking.UpdateExampleLinks();
    SymbolAnalysis.UpdateDetails();  // [Note: Expensive analysis]
    _wasScanned = true;
}
```

Once scanned, filter data is available for the session.

---

## Code Trace: Building a Tree from a Flat Symbol List

Let us walk through tree construction for a small symbol set.

### Symbols

| Symbol Name | Namespace |
|-------------|-----------|
| Blur | Lib.Image.Filter |
| Sharpen | Lib.Image.Filter |
| GenerateMesh | Lib.3d.mesh |
| MyEffect | t3.Internal |
| CustomTool | MyProject.Tools |

### Initial State

```
root (Children=[], Symbols=[])
```

### After Sorting

Priority order: Lib (0), Types (1), Examples (2), t3 (3), Everything else (MaxValue)

Sorted insertion order:
1. Blur (Lib.Image.Filter) — priority 0
2. GenerateMesh (Lib.3d.mesh) — priority 0
3. Sharpen (Lib.Image.Filter) — priority 0
4. MyEffect (t3.Internal) — priority 3
5. CustomTool (MyProject.Tools) — priority MaxValue

### Inserting Blur (Lib.Image.Filter)

Split: `["Lib", "Image", "Filter"]`

1. "Lib" not found → create, `expandingSubTree = true`
2. "Image" → create (expanding)
3. "Filter" → create (expanding)
4. Add Blur to Filter.Symbols

```
root
└── Lib
    └── Image
        └── Filter (Symbols=[Blur])
```

### Inserting GenerateMesh (Lib.3d.mesh)

Split: `["Lib", "3d", "mesh"]`

1. "Lib" found → reuse
2. "3d" not found → create, `expandingSubTree = true`
3. "mesh" → create (expanding)
4. Add GenerateMesh to mesh.Symbols

```
root
└── Lib
    ├── Image
    │   └── Filter (Symbols=[Blur])
    └── 3d
        └── mesh (Symbols=[GenerateMesh])
```

### Inserting Sharpen (Lib.Image.Filter)

Split: `["Lib", "Image", "Filter"]`

1. "Lib" found → reuse
2. "Image" found → reuse
3. "Filter" found → reuse
4. Add Sharpen to Filter.Symbols

```
root
└── Lib
    ├── Image
    │   └── Filter (Symbols=[Blur, Sharpen])
    └── 3d
        └── mesh (Symbols=[GenerateMesh])
```

### Final Tree (all symbols inserted)

```
root
├── Lib
│   ├── Image
│   │   └── Filter (Symbols=[Blur, Sharpen])
│   └── 3d
│       └── mesh (Symbols=[GenerateMesh])
├── t3
│   └── Internal (Symbols=[MyEffect])
└── MyProject
    └── Tools (Symbols=[CustomTool])
```

Notice how the tree preserves the priority ordering: Lib comes first, then t3, then MyProject.

---

## Edge Cases and Gotchas

Here is something that might trip you up when working with this code.

### Null Namespaces

```csharp
if (symbol.Namespace == null)
    return;
```

Operators without namespaces are silently skipped. They do not appear in the tree at all. This is intentional—namespace-less operators are typically internal implementation details. If you are wondering why an operator is missing from the library view, check whether it has a namespace assigned.

### Empty Segments

```csharp
if (spaceName == "")
    continue;
```

A namespace like `"Lib..Filter"` (double dot) or `"Lib.Filter."` (trailing dot) produces empty segments when split. These are ignored to prevent creating nodes with empty names. You might not expect this behavior if you are debugging a malformed namespace string.

### Tree Reuse vs Rebuild

The tree is rebuilt from scratch each time `PopulateCompleteTree()` is called:

```csharp
Clear();
```

This simplicity avoids complex synchronization logic. If an operator is deleted, renamed, or its namespace changes, the next rebuild reflects reality. The cost is acceptable because rebuilding 500 operators takes milliseconds.

### The Root Node is Never Rendered

Here is where it gets interesting. The root node exists purely as a container. The rendering code in `SymbolLibrary.cs` (not `NamespaceTreeNode.cs`) skips it:

```csharp
// In SymbolLibrary.DrawNode():
if (subtree.Name == NamespaceTreeNode.RootNodeId)
{
    DrawNodeItems(subtree);  // [Note: Draw children directly, skip the root itself]
}
```

Top-level namespaces (Lib, Types, Examples) appear as the first visible level in the UI. If you are looking for where this happens, check `SymbolLibrary.cs`, not the tree node class itself.

---

## Design Insights

### Why Parse Namespace Strings?

An alternative design would store hierarchy directly—each symbol knows its parent namespace object, not a string. This would make tree construction trivial but complicate serialization and namespace renaming.

By using strings, Tooll3 keeps the data model simple. Namespaces are just string properties on symbols. The tree is a derived structure, computed when needed and discarded when stale.

### Why Priority Ordering?

Without priority ordering, namespaces would appear alphabetically. "Examples" would come before "Lib". But users spend most of their time in the standard library—it should appear first.

The priority list (`["Lib.", "Types.", "Examples.", "t3."]`) encodes organizational preferences. Standard library first, types second, examples for learning third, internal framework code fourth, user code last.

### Why OR Semantics for Filters?

The filtering system uses OR: "show operators matching ANY active filter." This fits the use case of finding problems to fix. You activate "missing description" and "unused" to see all operators needing attention.

AND semantics would be too restrictive—"missing description AND unused" is a small intersection. OR semantics show the union of all problems.

---

## Summary

The namespace tree transforms flat namespace strings into a browsable hierarchy:

- **NamespaceTreeNode** — Recursive structure with name, children, parent, and symbols
- **GetAsString()** — Walks parent chain to reconstruct full namespace path
- **PopulateCompleteTree()** — Entry point that sorts operators by priority and builds tree
- **SortInOperator()** — Splits namespace, traverses/creates nodes, inserts symbol
- **Predicate filtering** — Builds partial trees matching criteria
- **LibraryFiltering** — UI for quality-based filters using bitmask flags

The tree is a derived structure, rebuilt from scratch when needed. This simplicity avoids synchronization complexity while remaining fast enough for interactive use.

---

**Previous:** [Symbol Library Window](01-symbol-library.md) | **Next:** [Search & Relevance](../graph/02-search-relevance.md)
