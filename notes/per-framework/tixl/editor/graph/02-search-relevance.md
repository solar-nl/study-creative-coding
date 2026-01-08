# Chapter 2: Search & Relevance Scoring

> *Type "ds" and DrawState appears first—not DrawSquare, not DataSource. The search is not magic; it is math.*

**Previous:** [The Symbol Browser Popup](01-symbol-browser.md) | **Next:** [Connection Making](03-connection-making.md)

---

## The Problem: Too Many Results, Wrong Order

Open the Symbol Browser and type "d". You get 150 matches. Type "dr" and it drops to 40. Type "draw" and suddenly there are 25 operators competing for your attention: DrawBillboards, DrawLines, DrawMesh, DrawQuad, DrawRibbons, DrawState...

Simple string matching—"does the name contain my query?"—gets you matches. But matches are not enough. Users expect Google-like intelligence: the *right* result at the top, not buried at position 47.

Consider these two users:

1. **Alice** works in Project "ShaderLab" and types "blur". She wants the custom blur operator she wrote yesterday, not the library's generic Blur.

2. **Bob** is new to the system and types "ds". He wants DrawState—the most commonly used operator—not some obscure internal helper called `_DataStash`.

Both need fuzzy matching (ds matches DrawState). Both need smart ranking. But their contexts differ. The search system must weigh multiple signals—string similarity, usage patterns, project context, symbol visibility—and combine them into a single relevance score.

This chapter explores how `SymbolFilter` transforms a three-character query into a precisely ranked list of 500+ operators.

---

## The Mental Model: Search Engine Ranking

Think of the Symbol Browser as a tiny search engine. Like Google, it does not simply find pages containing your keywords—it *ranks* them. A page that mentions "cats" once in the footer ranks lower than a page titled "Everything About Cats" with cat content throughout.

The same principle applies here. Multiple weak signals combine into strong relevance:

```
String matching          → Does the name even match?
Position matching        → Match at start vs. middle?
Case pattern matching    → Does "ds" match "DrawState" initials?
Namespace context        → Is this a library operator or internal helper?
Project proximity        → Is this from my project or a dependency?
Usage frequency          → How often do people actually use this?
Deprecation status       → Is this obsolete?
```

Each signal contributes a multiplier. The final score is their product. A high score on one dimension cannot compensate for zero on another—you need good signals across the board to rank well.

---

## Fuzzy Matching: From Characters to Regex

Let's start with the most visible part of search: the fuzzy matching that lets "abc" find "AddBlendColors".

### The Transformation

When you type into the search box, `UpdateFilters()` transforms your query into a regular expression:

```csharp
var pattern = string.Join(".*", symbolFilter.ToCharArray());
// "abc" → "a.*b.*c"
// "ds"  → "d.*s"
// "blur" → "b.*l.*u.*r"
```

The pattern reads: "find 'a', then anything, then 'b', then anything, then 'c'". This matches:
- **A**dd**B**lend**C**olors
- **A**d**B**rowse**C**ommand
- **Ab**stract**C**ontainer

The regex uses case-insensitive matching:

```csharp
searchRegex = new Regex(pattern, RegexOptions.IgnoreCase);
```

So "DS" and "ds" both match "DrawState".

### Exception Handling

User input is unpredictable. What if someone types a literal regex character like `[` or `*`? The pattern `[.*` is invalid regex—the bracket is never closed.

Rather than crashing or silently failing, the code catches the exception and continues:

```csharp
try
{
    searchRegex = new Regex(pattern, RegexOptions.IgnoreCase);
}
catch (ArgumentException)
{
    Log.Debug("Invalid Regex format: " + pattern);
    return true;  // Signal that update happened (filter changed)
}
```

The filter remains unchanged from its previous valid state. Users can continue typing to fix their query.

---

## Two-Part Search: Symbol Plus Preset

Sometimes you know exactly what operator you want *and* which preset to apply. The search box supports a two-part syntax:

```
"DrawState blur"
     ↓
Symbol filter: "DrawState"
Preset filter: "blur"
```

The split happens on the first whitespace:

```csharp
var twoPartSearchResult = new Regex(@"(.+?)\s+(.*)").Match(search);
if (twoPartSearchResult.Success)
{
    symbolFilter = twoPartSearchResult.Groups[1].Value;  // "DrawState"
    presetFilter = twoPartSearchResult.Groups[2].Value;  // "blur"
}
else
{
    symbolFilter = search;
    presetFilter = string.Empty;
}
```

The regex `(.+?)\s+(.*)` captures:
- Group 1: One or more characters (non-greedy) before whitespace
- Group 2: Everything after the whitespace

When a preset filter is active, the Symbol Browser switches from showing operator descriptions to showing matching presets (covered in Chapter 1). The relevancy scoring we discuss here applies to the *symbol* filter—the first part of the query.

---

## The Matching Phase: Filtering Before Scoring

Before scoring can begin, we need candidates. The `UpdateMatchingSymbols()` method iterates through all registered symbols and applies three filters:

### Filter 1: Cycle Prevention

You cannot insert a symbol that would create a circular dependency. If you are editing `CompositionA`, which contains `CompositionB`, which contains `CompositionC`, you cannot insert any of those three—doing so would create an infinite loop.

```csharp
var compositionInstance = selection?.GetSelectedComposition();
ICollection<Guid> parentSymbolIds = compositionInstance != null
    ? new HashSet<Guid>(
          Structure.CollectParentInstances(compositionInstance)
              .Append(compositionInstance)
              .Select(p => p.Symbol.Id))
    : Array.Empty<Guid>();

foreach (var symbolUi in EditorSymbolPackage.AllSymbolUis)
{
    if (parentSymbolIds.Contains(symbolUi.Symbol.Id))
        continue;  // Skip—would create cycle
    // ...
}
```

`Structure.CollectParentInstances()` walks up the composition hierarchy and returns all ancestor instances. Their IDs go into a `HashSet` for O(1) lookup. Any symbol that would close a loop is silently excluded from results.

### Filter 2: Type Constraints

When you drag a connection from a `Texture2D` output and drop on empty canvas, only operators accepting `Texture2D` should appear. The type constraints are applied as early exclusion criteria:

```csharp
if (_inputType != null)
{
    if (symbolUiSymbol.InputDefinitions.Count == 0
        || symbolUiSymbol.InputDefinitions[0].ValueType != _inputType)
        continue;

    var matchingInputDef = symbolUiSymbol.GetInputMatchingType(FilterInputType);
    if (matchingInputDef == null)
        continue;

    if (OnlyMultiInputs && !symbolUiSymbol.InputDefinitions[0].IsMultiInput)
        continue;
}

if (_outputType != null)
{
    var matchingOutputDef = symbolUiSymbol.GetOutputMatchingType(FilterOutputType);
    if (matchingOutputDef == null)
        continue;
}
```

The `GetInputMatchingType()` and `GetOutputMatchingType()` methods check for type compatibility including inheritance—if an operator accepts `TextureBase`, it also accepts `Texture2D`.

The `OnlyMultiInputs` flag further restricts results to operators with variadic first inputs (like `Add` which can take any number of values).

### Filter 3: String Matching

Only symbols that actually match the search pattern pass through:

```csharp
if (!(_currentRegex.IsMatch(symbolUiSymbol.Name)
      || symbolUiSymbol.Namespace.Contains(_symbolFilterString,
              StringComparison.InvariantCultureIgnoreCase)
      || (!string.IsNullOrEmpty(symbolUi.Description)
          && symbolUi.Description.Contains(_symbolFilterString,
              StringComparison.InvariantCultureIgnoreCase))))
    continue;
```

Notice the three-way OR condition:

1. **Name matches regex** — The fuzzy pattern (ds → d.*s)
2. **Namespace contains query** — Typing "lib" shows all library operators
3. **Description contains query** — Typing "gaussian" finds operators described as "Applies Gaussian blur"

This is intentional: the regex fuzzy matching applies only to names, while namespace and description use simple substring matching. This prevents false positives where "lib" would fuzzy-match symbol names with scattered l-i-b letters.

---

## The Scoring Phase: Computing Relevancy

Matching tells us *if* a symbol should appear. Scoring tells us *where* it should rank. The `ComputeRelevancy()` method returns a floating-point score used for sorting.

The algorithm is simple: start at 1.0, then apply a series of multipliers based on various signals. Higher scores rank higher.

### The Complete Scoring Table

| Factor | Multiplier | When Applied |
|--------|------------|--------------|
| Types namespace | ×4.0 | Namespace starts with "Types." (e.g., Types.Vec3) |
| Exact name match | ×8.6 | Query equals name (case-insensitive) |
| Starts-with match | ×8.5 | Name starts with query |
| Contains match | ×8.4 | Name contains query (not at start) |
| Description match | ×1.01 | Description contains query |
| PascalCase match | ×4.0 | Uppercase query chars match name sequence |
| Lib namespace | ×3.0 | Namespace starts with "Lib" |
| Examples namespace | ×2.0 | Namespace starts with "examples" |
| dx11/underscore namespace | ×0.1 | Namespace contains "dx11" or "_" |
| Underscore prefix | ×0.1 | Symbol name starts with "_" |
| Obsolete | ×0.01 | Symbol name contains "OBSOLETE" |
| Same project | ×2.0 | Symbol is from current project package |
| Same root namespace | ×1.9 | Symbol namespace starts with project's root |
| Same package as composition | ×1.9 | Symbol's package matches composition's |
| Editable symbol | ×1.9 | Symbol is in an editable project (not readonly) |
| Matching input connections | ×(1 + count^0.33 × 4) | Historical connections suggest relevance |
| Usage frequency | ×(1 + 500 × count/total) | How often this symbol is used globally |

Let's trace through the most important factors.

---

## String Match Scoring: Precision Matters

The first batch of multipliers rewards increasingly precise string matches:

```csharp
if (symbolName.Equals(query, StringComparison.InvariantCultureIgnoreCase))
{
    relevancy *= 8.6f;  // Exact match
}

if (symbolName.StartsWith(query, StringComparison.InvariantCultureIgnoreCase))
{
    relevancy *= 8.5f;  // Starts-with match
}
else
{
    if (symbolName.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)
    {
        relevancy *= 8.4f;  // Contains match
    }
}
```

Notice these are not mutually exclusive. An exact match gets *both* the 8.6 and 8.5 multipliers (since an exact match also starts with the query). Final score: 8.6 × 8.5 = 73.1×.

The multipliers are deliberately close (8.6 vs 8.5 vs 8.4) so that other factors can differentiate among similar matches. If exact matches got 100× and contains got 1×, no other signal would matter.

### PascalCase Matching: The "ds → DrawState" Trick

This is perhaps the cleverest scoring factor. The algorithm converts your query to uppercase, then checks if each uppercase character appears in order within the symbol name (case-sensitive search):

```csharp
var pascalCaseMatch = true;

var uppercaseQuery = query.ToUpper();  // "ds" → "DS"
var maxIndex = 0;

foreach (var indexInName in uppercaseQuery.Select(c => symbolName.IndexOf(c, maxIndex)))
{
    if (indexInName == -1)
    {
        pascalCaseMatch = false;
        break;
    }
    maxIndex = indexInName + 1;  // Next search starts after this match
}

if (pascalCaseMatch)
{
    relevancy *= 4f;
}
```

For "ds" matching against "DrawState":
1. Query becomes "DS"
2. Find 'D' in "DrawState" starting at 0 → found at 0
3. Find 'S' in "DrawState" starting at 1 → found at 4
4. Both found in order → PascalCase match!

For "ds" matching against "datastore":
1. Query becomes "DS"
2. Find 'D' in "datastore" → not found (lowercase 'd' doesn't match 'D')
3. No match

The key insight: the query is uppercased, but the search in the symbol name is case-sensitive. This means "ds" matches "DrawState" (uppercase D and S exist) but not "datastore" (only lowercase letters). This naturally favors PascalCase names where capital letters mark word boundaries.

Both "DrawState" and "DataSource" match "ds", so both get the ×4 boost. But "DrawState" likely also gets the ×8.5 starts-with boost from "d" matching "Draw...", pushing it ahead.

---

## Context Scoring: Project and Namespace Proximity

Two users typing the same query may want different results. Context scoring personalizes rankings:

### Same Project Boost

Operators from your current project rank higher:

```csharp
if (currentProject != null)
{
    if (currentProject == symbolPackage)
    {
        relevancy *= 2f;  // Same package as current project
    }
    else if (symbol.Namespace!.StartsWith(currentProject.RootNamespace))
    {
        relevancy *= 1.9f;  // Same root namespace
    }
}
```

If you are working in the "ShaderLab" project and have a custom "Blur" operator there, it outranks the library's "Blur" by 2×.

### Composition Package Boost

Operators from the same package as your current composition also rank higher:

```csharp
if (composition != null)
{
    var compositionSymbol = composition.Symbol;
    var compositionPackage = compositionSymbol.SymbolPackage;

    if (compositionPackage.Symbols.ContainsKey(symbolId)
        || symbolPackage.RootNamespace.StartsWith(compositionPackage.RootNamespace))
    {
        relevancy *= 1.9f;
    }
}
```

### Editable Symbol Boost

Symbols you can actually edit (your own code, not library code) get a boost:

```csharp
if (symbolPackage is EditableSymbolProject)
{
    relevancy *= 1.9f;
}
```

This subtly prioritizes user-created content over read-only library content.

---

## Namespace Penalties: Hiding Internal Symbols

Not all operators deserve equal visibility. Internal helpers, deprecated operators, and legacy compatibility shims should fade into the background:

```csharp
if (!string.IsNullOrEmpty(symbol.Namespace))
{
    if (symbol.Namespace.Contains("dx11") || symbol.Namespace.Contains("_"))
        relevancy *= 0.1f;  // Legacy/internal namespace

    if (symbol.Namespace.StartsWith("Lib"))
        relevancy *= 3f;  // Library namespace boost
}

if (symbolName.StartsWith("_"))
{
    relevancy *= 0.1f;  // Internal symbol (underscore prefix)
}

if (symbolName.Contains("OBSOLETE"))
    relevancy *= 0.01f;  // Deprecated
```

A symbol named `_InternalHelper` in namespace `lib_dx11_compat` would get:
- ×0.1 for underscore in namespace
- ×0.1 for underscore prefix in name
- Final: 0.01× (pushed to bottom of results)

An obsolete symbol gets ×0.01—essentially invisible unless you specifically search for it.

---

## Usage Frequency: Popularity Matters

Perhaps the most powerful signal is usage frequency. Operators that appear often in existing graphs are probably more useful:

```csharp
if (relevancy > 10f)  // Only boost if already somewhat relevant
{
    var count = SymbolAnalysis.InformationForSymbolIds.TryGetValue(symbol.Id, out var info)
                    ? info.UsageCount
                    : 0;

    var totalUsageCountBoost = (float)(1 + (500.0 * count / SymbolAnalysis.TotalUsageCount));
    relevancy *= totalUsageCountBoost;
}
```

The formula `1 + 500 × (count/total)` means:
- Unused symbol → multiplier of 1 (no change)
- Symbol with 1% of total usage → multiplier of 6
- Symbol with 10% of total usage → multiplier of 51

The `relevancy > 10f` threshold prevents boosting irrelevant results. If a symbol barely matches your query, high usage should not rescue it.

### Connection History Boost

A more targeted signal: how often has *this specific output type* connected to *this specific input type*?

```csharp
var matchingInputConnectionsCount = 0;
if (targetInputHash != 0)
{
    foreach (var outputDefinition in symbol.OutputDefinitions
                 .FindAll(o => o.ValueType == filterOutputType))
    {
        var connectionHash = outputDefinition.Id.GetHashCode() * 31 + targetInputHash;

        if (SymbolAnalysis.ConnectionHashCounts.TryGetValue(connectionHash, out var connectionCount))
        {
            matchingInputConnectionsCount += connectionCount;
        }
    }
}

if (matchingInputConnectionsCount > 0)
{
    var matchingInputsBoost = 1 + MathF.Pow(matchingInputConnectionsCount, 0.33f) * 4f;
    relevancy *= matchingInputsBoost;
}
```

If users frequently connect "Noise.Output" to "Blur.Input", then when dragging from a Noise output, Blur gets boosted. The cube-root `Pow(count, 0.33f)` prevents very popular connections from completely dominating.

---

## Putting It Together: A Complete Trace

Let's trace `ComputeRelevancy()` for a concrete example. User types "blur" in project "ShaderLab":

**Candidate: Library Blur operator**
```
Base score:                          1.0
Namespace "Lib.Image"
  - Starts with "Lib" → ×3.0         3.0
Name "Blur"
  - Equals "blur" → ×8.6            25.8
  - StartsWith "blur" → ×8.5       219.3
PascalCase match (BLUR in Blur) → ×4  877.2
No project match                   877.2
Editable? No (library)             877.2
Usage: 847 uses out of 50000
  - Boost: 1 + 500×(847/50000) = 9.47
  - Final: 877.2 × 9.47            8307
```

**Candidate: User's custom FastBlur operator**
```
Base score:                          1.0
Namespace "ShaderLab.Effects"
  - No "Lib" prefix                  1.0
Name "FastBlur"
  - Contains "blur" → ×8.4           8.4
PascalCase match (BLUR in FastBlur) → ×4  33.6
Project match:
  - Same project → ×2.0             67.2
  - Same root namespace → ×1.9     127.7
Editable? Yes → ×1.9               242.6
Usage: 12 uses out of 50000
  - Boost: 1 + 500×(12/50000) = 1.12
  - Final: 242.6 × 1.12            272
```

Library Blur wins with 8307 vs 272 despite the project boosts. The usage frequency of the library operator (847 uses) overwhelms the custom operator's project affinity.

But change the scenario: what if user types "fastb"?

**Candidate: FastBlur**
```
Name "FastBlur"
  - StartsWith "fastb" → ×8.5
  - PascalCase match → ×4
  - Plus project boosts...
```

**Candidate: Library Blur**
```
Name "Blur"
  - Does not match "fastb" regex
  - Filtered out entirely
```

Now FastBlur wins by being the only match. The system balances between popularity (library operators) and specificity (custom operators) based on query precision.

---

## Result Capping: The Top 100

After scoring all matches, the results are sorted and capped:

```csharp
if (limit == 0)
{
    MatchingSymbolUis = MatchingSymbolUis
        .OrderBy(s => ComputeRelevancy(s, _symbolFilterString, currentProject, composition))
        .Reverse()
        .Take(100)
        .ToList();
}
else
{
    MatchingSymbolUis = MatchingSymbolUis
        .OrderBy(s => ComputeRelevancy(s, _symbolFilterString, currentProject, composition))
        .Reverse()
        .Take(limit)
        .ToList();
}
```

The default limit of 100 is a performance and UX tradeoff:
- More than 100 results is overwhelming—no one scrolls that far
- Computing relevancy for 500+ symbols is already O(n); rendering 500 UI elements would be worse
- The limit parameter allows callers to request fewer (e.g., autocomplete might want top 10)

---

## Edge Cases

### Empty Search String

When `SearchString` is empty, `String.Join(".*", "".ToCharArray())` returns an empty string (not `.*`). An empty regex pattern matches at position 0 of every string, so every symbol passes the name filter. Ranking then depends entirely on context factors: project proximity, usage frequency, namespace reputation.

```csharp
var pattern = string.Join(".*", symbolFilter.ToCharArray());
// "" → "" (empty string, not ".*")
// Empty regex matches everything (matches at position 0)
```

The result: most popular operators from your project appear first.

### Namespace-Only Matches

Typing "lib.image" finds operators in that namespace even if their names do not match:

```csharp
|| symbolUiSymbol.Namespace.Contains(_symbolFilterString,
       StringComparison.InvariantCultureIgnoreCase)
```

This allows browsing by category. But namespace matches get no string-matching score boost (no ×8.4 for contains), so they rank lower than name matches.

### Description-Only Matches

Searching for "gaussian" might find an operator named "SmoothBlur" with description "Applies Gaussian blur kernel". This broadens discovery but ranks lower because description matches only get ×1.01:

```csharp
if (!string.IsNullOrEmpty(symbolUi.Description)
    && symbolUi.Description.Contains(query, StringComparison.InvariantCultureIgnoreCase))
{
    relevancy *= 1.01f;
}
```

The 1% boost is intentional—it is a tiebreaker, not a primary signal. An operator named "Gaussian" still outranks one merely described as gaussian.

---

## Performance Considerations

The scoring algorithm runs once per matching symbol, every time the search string changes. With 500+ symbols and 60fps UI, this must be fast.

Several design choices optimize performance:

1. **Early filtering** — Cycle prevention, type constraints, and string matching happen before scoring. Only survivors get scored.

2. **Multiplicative scores** — Floating-point multiplication is cheaper than string operations or collection lookups.

3. **Cached usage data** — `SymbolAnalysis.InformationForSymbolIds` is precomputed, not calculated per query.

4. **Result limit** — Scoring produces ranked order, but only the top 100 survive. Sorting 500 elements is O(n log n), but we could theoretically use partial sort for O(n + k log k) where k=100.

5. **Change detection** — `UpdateIfNecessary()` tracks `_lastSearchString` and skips recomputation if nothing changed.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `Editor/UiModel/Helpers/SymbolFilter.cs` | Filter logic, regex building, relevancy scoring |
| `Editor/UiModel/SymbolAnalysis.cs` | Usage statistics, connection history |
| `Editor/Gui/Graph/Legacy/Interaction/SymbolBrowser.cs` | UI integration, preset panel |

---

## Summary

The Symbol Browser's search is not magic—it is a carefully tuned ranking system:

1. **Fuzzy matching** — "ds" becomes regex `d.*s`, finding DrawState
2. **Two-part search** — Space splits symbol from preset filter
3. **Three-stage filtering** — Cycle prevention, type constraints, string matching
4. **Multi-factor scoring** — 12+ signals multiply into final relevance
5. **Context awareness** — Project proximity and usage history personalize rankings
6. **Defensive penalties** — Underscore prefixes and "OBSOLETE" markers sink results

The multiplier-based approach means each signal contributes proportionally. Exact name matches dominate. Usage frequency breaks ties among similar matches. Project affinity lifts your own code. And deprecated operators effectively disappear.

The result: type "ds" and DrawState appears first—not by magic, but by math.

---

**Previous:** [The Symbol Browser Popup](01-symbol-browser.md) | **Next:** [Connection Making](03-connection-making.md)
