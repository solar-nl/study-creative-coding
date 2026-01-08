# MagGraph Operator Browser - Technische Documentatie

Dit document beschrijft de IMGUI-gebaseerde operator browser in het MagGraph systeem. De browser stelt gebruikers in staat om operators te zoeken, filteren en toe te voegen aan de grafiek.

## Architectuur Overzicht

```
┌─────────────────────────────────────────────────────────────────┐
│                    PlaceholderCreation                          │
│         (Bepaalt wanneer/hoe de browser opent)                  │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                      PlaceHolderUi                              │
│            (Hoofd UI - zoeken + resultaten)                     │
├─────────────────────────┬───────────────────────────────────────┤
│   DrawSearchInput()     │         DrawResultsList()             │
│   - Zoekveld            │         - Resultatenlijst             │
│   - Keyboard input      │         - Entry rendering             │
└─────────────────────────┴───────────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
┌─────────────────────┐       ┌─────────────────────────────────┐
│   SymbolBrowsing    │       │         SymbolFilter            │
│ (Hiërarchische      │       │   (Zoeken + Relevancy Scoring)  │
│  tree navigatie)    │       │                                 │
└─────────────────────┘       └─────────────────────────────────┘
```

## Bestanden

| Bestand | Pad | Beschrijving |
|---------|-----|--------------|
| PlaceHolderUi.cs | `Editor/Gui/MagGraph/Interaction/PlaceHolderUi.cs` | Hoofd UI component |
| SymbolBrowsing.cs | `Editor/Gui/MagGraph/Interaction/SymbolBrowsing.cs` | Hiërarchische tree browser |
| PlaceholderCreation.cs | `Editor/Gui/MagGraph/Interaction/PlaceholderCreation.cs` | Trigger logica |
| SymbolFilter.cs | `Editor/UiModel/Helpers/SymbolFilter.cs` | Filter en relevancy algoritme |

---

## PlaceHolderUi.cs

**Locatie:** `Editor/Gui/MagGraph/Interaction/PlaceHolderUi.cs`

Dit is de centrale UI-klasse die het zoekvenster en de resultatenlijst rendert.

### Belangrijke Methodes

#### `Open()` (regel 26-49)
Opent de operator browser met optionele type filters.

```csharp
internal static void Open(
    GraphUiContext context,
    MagGraphItem placeholderItem,
    MagGraphItem.Directions connectionOrientation = MagGraphItem.Directions.Horizontal,
    Type? inputFilter = null,
    Type? outputFilter = null)
```

**Parameters:**
- `context` - De huidige grafiek context
- `placeholderItem` - De placeholder positie op het canvas
- `connectionOrientation` - Richting van de connectie (Horizontal/Vertical)
- `inputFilter` - Filter op input type (optioneel)
- `outputFilter` - Filter op output type (optioneel)

#### `Draw()` (regel 60-97)
Hoofd render loop die elke frame wordt aangeroepen.

```csharp
internal static UiResults Draw(GraphUiContext context, out SymbolUi? selectedUi)
```

**Returns:** `UiResults` flags die aangeven wat er is gebeurd:
- `None` - Geen actie
- `SelectionChanged` - Andere operator geselecteerd
- `FilterChanged` - Zoekfilter gewijzigd
- `Create` - Gebruiker wil operator aanmaken
- `Cancel` - Gebruiker heeft geannuleerd
- `ClickedOutside` - Klik buiten de browser

#### `DrawSearchInput()` (regel 108-222)
Rendert het zoekveld met ImGui.

**Belangrijke ImGui calls:**
```csharp
// Regel 158: Zoekveld input
ImGui.InputText("##symbolBrowserFilter",
                ref Filter.SearchString,
                20,
                ImGuiInputTextFlags.AutoSelectAll);

// Regel 184: Enter-toets detectie
if (ImGui.IsKeyPressed((ImGuiKey)Key.Return))
{
    if (_selectedSymbolUi != null)
    {
        uiResult |= UiResults.Create;
    }
}

// Regel 205: Escape-toets detectie
var shouldCancelConnectionMaker = ImGui.IsKeyDown((ImGuiKey)Key.Esc);
```

#### `DrawResultsList()` (regel 224-321)
Rendert de scrollbare lijst met zoekresultaten.

**Belangrijke ImGui calls:**
```csharp
// Regel 248-251: Style configuratie
ImGui.PushStyleVar(ImGuiStyleVar.ChildRounding, 6);
ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 14);
ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, new Vector2(6, 6));
ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, new Vector2(3, 6));

// Regel 286-291: Child window voor scrollbare lijst
bool childOpen = ImGui.BeginChild(
    999,
    last,
    true,
    ImGuiWindowFlags.AlwaysUseWindowPadding | ImGuiWindowFlags.NoResize);
```

#### `DrawSearchResultEntries()` (regel 344-401)
Rendert de gefilterde operator entries met `ImGuiListClipper` voor performance.

**ImGuiListClipper gebruik:**
```csharp
// Regel 381-395: Virtualized list rendering
ImGuiListClipperPtr clipper = new ImGuiListClipperPtr(
    ImGuiNative.ImGuiListClipper_ImGuiListClipper());

clipper.Begin(count, _rowHeight);

while (clipper.Step())
{
    for (int i = clipper.DisplayStart; i < clipper.DisplayEnd; i++)
    {
        var symbolUi = filter.MatchingSymbolUis[i];
        result |= DrawSymbolUiEntry(context, symbolUi);
    }
}

clipper.End();
```

#### `DrawSymbolUiEntry()` (regel 403-466)
Rendert een individuele operator entry met kleuren gebaseerd op output type.

```csharp
// Regel 413-415: Kleur bepalen op basis van output type
var color = symbolUi.Symbol.OutputDefinitions.Count > 0
    ? TypeUiRegistry.GetPropertiesForType(symbolUi.Symbol.OutputDefinitions[0]?.ValueType).Color
    : UiColors.Gray;

// Regel 436-443: Selectable item
if (ImGui.Selectable($"##Selectable{symbolHash}",
                     isSelected,
                     ImGuiSelectableFlags.None,
                     new Vector2(size.X, 0)))
{
    result |= UiResults.Create;
    _selectedSymbolUi = symbolUi;
}

// Regel 450-457: Tooltip met help informatie
if (isHovered)
{
    ImGui.SetNextWindowSize(new Vector2(300, 0));
    ImGui.BeginTooltip();
    OperatorHelp.DrawHelpSummary(symbolUi, false);
    ImGui.EndTooltip();
}
```

### Keyboard Navigatie

```csharp
// Regel 348-357: Pijltjestoetsen navigatie
if (ImGui.IsKeyReleased((ImGuiKey)Key.CursorDown))
{
    UiListHelpers.AdvanceSelectedItem(filter.MatchingSymbolUis!, ref _selectedSymbolUi, 1);
}
else if (ImGui.IsKeyReleased((ImGuiKey)Key.CursorUp))
{
    UiListHelpers.AdvanceSelectedItem(filter.MatchingSymbolUis!, ref _selectedSymbolUi, -1);
}
```

---

## SymbolBrowsing.cs

**Locatie:** `Editor/Gui/MagGraph/Interaction/SymbolBrowsing.cs`

Biedt een hiërarchische tree-gebaseerde navigatie door operators georganiseerd per namespace/categorie.

### Tree Structuur

De browser organiseert operators in een boom:

```
Lib (Project)
├── numbers (NamespaceCategory)
│   ├── anim (Page)
│   │   ├── time (Namespace)
│   │   ├── animators (Namespace)
│   │   └── vj (Namespace)
│   ├── float (Page)
│   │   ├── basic (Namespace)
│   │   ├── trigonometry (Namespace)
│   │   └── ...
│   ├── vec2 (Namespace)
│   ├── vec3 (Namespace)
│   └── color (Namespace)
├── image (NamespaceCategory)
│   ├── generate (Page)
│   ├── fx (Page)
│   └── ...
├── point (NamespaceCategory)
├── render (NamespaceCategory)
└── misc (Grouping)
```

### Varianten

```csharp
private enum Variants
{
    Project,           // Root node
    Page,              // Navigeerbare subpagina
    NamespaceCategory, // Categorie met namespaces
    Namespace,         // Daadwerkelijke namespace met operators
    Grouping,          // Logische groepering
}
```

### Draw Methode (regel 18-184)

Rendert de tree recursief gebaseerd op het huidige pad.

**Category Header rendering (regel 103-106):**
```csharp
var color = ColorVariations.OperatorLabel.Apply(
    TypeUiRegistry.GetPropertiesForType(group.Type).Color);
ImGui.PushStyleColor(ImGuiCol.Text, color.Rgba);
ImGui.TextUnformatted($"{group.Name}...");
ImGui.PopStyleColor();
```

**Namespace navigatie (regel 108-113):**
```csharp
if (ImGui.IsItemClicked())
{
    _path.Clear();
    _path.AddRange([..groupPath, group]);
    ImGui.SetScrollY(0);
}
```

### Tree Definitie (regel 225-321)

De complete tree wordt gedefinieerd in `UpdateLibPage()`:

```csharp
private static Group UpdateLibPage()
{
    return new Group(Variants.Project, "Lib",
        [
            new Group(Variants.NamespaceCategory, "numbers", [
                new Group(Variants.Page, "anim", [
                    new Group(Variants.Namespace, "time"),
                    new Group(Variants.Namespace, "animators"),
                    // ...
                ]),
                // ...
            ]),
            new Group(Variants.NamespaceCategory, "image", [
                new Group(Variants.Page, "generate", [
                    new Group(Variants.Namespace, "load", type: typeof(Texture2D)),
                    // ...
                ], type: typeof(Texture2D)),
                // ...
            ]),
            // ... meer categorieën
        ]);
}
```

---

## PlaceholderCreation.cs

**Locatie:** `Editor/Gui/MagGraph/Interaction/PlaceholderCreation.cs`

Beheert de lifecycle van de placeholder en bepaalt wanneer/hoe de browser opent.

### Open Triggers

#### `OpenToSplitHoveredConnections()` (regel 22-80)
Opent browser om een operator in te voegen op een bestaande connectie.

```csharp
// Regel 74-76: Open met input/output filter gebaseerd op connectie type
PlaceHolderUi.Open(context, PlaceholderItem,
                   inputFilter: firstHover.Connection.Type,
                   outputFilter: firstHover.Connection.Type);
```

#### `OpenOnCanvas()` (regel 82-97)
Opent browser op een lege canvas positie.

```csharp
// Regel 96: Open zonder output filter
PlaceHolderUi.Open(context, PlaceholderItem, inputFilter: inputTypeFilter);
```

#### `OpenForItemOutput()` (regel 99-157)
Opent browser vanaf de output van een bestaande operator.

```csharp
// Regel 148-152: Open met output type filter
PlaceHolderUi.Open(context,
                   PlaceholderItem,
                   direction,
                   outputLine.Output.ValueType,  // inputFilter
                   outputValueType);              // outputFilter
```

#### `OpenForItemInput()` (regel 184-276)
Opent browser om een operator te koppelen aan een input.

```csharp
// Regel 266-270: Open met input type filter
PlaceHolderUi.Open(context,
                   PlaceholderItem,
                   direction,
                   null,              // inputFilter
                   input.ValueType);  // outputFilter
```

### Update Loop (regel 318-329)

```csharp
internal void Update(GraphUiContext context)
{
    var uiResult = PlaceHolderUi.Draw(context, out var selectedUi);
    if (uiResult.HasFlag(PlaceHolderUi.UiResults.Create) && selectedUi != null)
    {
        CreateInstance(context, selectedUi.Symbol);
    }
    else if (uiResult.HasFlag(PlaceHolderUi.UiResults.Cancel))
    {
        Cancel(context);
    }
}
```

### Instance Creation (regel 331-580)

`CreateInstance()` handelt de daadwerkelijke aanmaak en bedrading van de nieuwe operator:

1. Maakt `AddSymbolChildCommand` aan
2. Haalt de nieuwe `SymbolChild` en `Instance` op
3. Koppelt connecties op basis van context (output/input snapping)
4. Past layout aan indien nodig (push items vertically/horizontally)
5. Opent parameter popup voor de nieuwe node

---

## SymbolFilter.cs

**Locatie:** `Editor/UiModel/Helpers/SymbolFilter.cs`

Implementeert het zoek- en relevancy-algoritme.

### Properties

```csharp
public string SearchString = string.Empty;
public Type? FilterInputType { get; set; }
public Type? FilterOutputType { get; set; }
public bool OnlyMultiInputs { get; set; }
public List<SymbolUi> MatchingSymbolUis { get; private set; }
```

### Filter Logica (regel 69-102)

Splitst zoekstring in symbool filter en preset filter:

```csharp
// "add 0.5" wordt gesplitst in:
// symbolFilter = "add"
// presetFilter = "0.5"

var twoPartSearchResult = new Regex(@"(.+?)\s+(.*)").Match(search);
if (twoPartSearchResult.Success)
{
    symbolFilter = twoPartSearchResult.Groups[1].Value;
    presetFilter = twoPartSearchResult.Groups[2].Value;
}
```

Regex pattern voor fuzzy matching:
```csharp
// "add" wordt "a.*d.*d"
var pattern = string.Join(".*", symbolFilter.ToCharArray());
searchRegex = new Regex(pattern, RegexOptions.IgnoreCase);
```

### Symbol Matching (regel 104-183)

Filtert symbolen op:
1. **Type compatibility** - Input/output type filters
2. **Regex match** - Op naam
3. **Namespace match** - Bevat zoekstring
4. **Description match** - Bevat zoekstring
5. **Graph cycles** - Voorkomt oneindige recursie

### Relevancy Scoring (regel 187-372)

`ComputeRelevancy()` berekent een score voor elke match:

| Factor | Multiplier | Beschrijving |
|--------|------------|--------------|
| Types namespace | x4 | Operators in Types.* namespace |
| Exact match | x8.6 | Naam is exact gelijk aan zoekstring |
| Starts with | x8.5 | Naam begint met zoekstring |
| Contains | x8.4 | Naam bevat zoekstring |
| Description match | x1.01 | Beschrijving bevat zoekstring |
| PascalCase match | x4 | "ds" matcht "DrawState" |
| Lib namespace | x3 | Operators in Lib.* namespace |
| Examples namespace | x2 | Operators in examples.* |
| Current project | x2 | Operator in zelfde project |
| Related namespace | x1.9 | Operator in gerelateerde namespace |
| Same package | x1.9 | Operator in zelfde package |
| Editable project | x1.9 | Operator is bewerkbaar |
| Usage count | variabel | Gebaseerd op hoe vaak operator gebruikt wordt |
| Matching connections | variabel | Boost voor operators die vaak met dit type verbonden worden |

**Negatieve factoren:**
| Factor | Multiplier | Beschrijving |
|--------|------------|--------------|
| dx11/underscore namespace | x0.1 | Legacy operators |
| Underscore prefix | x0.1 | Private/interne operators |
| OBSOLETE in naam | x0.01 | Verouderde operators |

### Voorbeeld Relevancy Berekening

Voor zoekterm "add" met operator "Add" in Lib.float.basic:

```
Base relevancy:        1.0
Exact match (x8.6):    8.6
Lib namespace (x3):   25.8
PascalCase (x4):     103.2
Usage count (50x):   ~150.0
```

---

## ImGui Componenten Gebruikt

| Component | Gebruik |
|-----------|---------|
| `ImGui.InputText()` | Zoekveld input |
| `ImGui.BeginChild()` | Scrollbare resultatenlijst container |
| `ImGui.Selectable()` | Klikbare operator entries |
| `ImGui.PushStyleColor()` / `PopStyleColor()` | Kleurcodering per type |
| `ImGui.IsKeyReleased()` | Keyboard navigatie |
| `ImGui.IsItemHovered()` | Tooltip triggers |
| `ImGui.BeginTooltip()` | Help tekst weergave |
| `ImGuiListClipper` | Virtualized rendering voor performance |
| `ImGui.PushStyleVar()` | Padding, spacing, rounding configuratie |

---

## Data Flow

```
User Input (keyboard/mouse)
        │
        ▼
┌───────────────────┐
│  PlaceHolderUi    │
│  DrawSearchInput  │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│   SymbolFilter    │
│ UpdateIfNecessary │
└─────────┬─────────┘
          │
          ├──► Regex matching
          ├──► Type filtering
          └──► Relevancy sorting
          │
          ▼
┌───────────────────┐
│ MatchingSymbolUis │ (gesorteerde lijst)
└─────────┬─────────┘
          │
          ▼
┌───────────────────────────────┐
│  PlaceHolderUi.DrawResultsList│
│  (met ImGuiListClipper)       │
└───────────────────────────────┘
          │
          ▼
    User Selection
          │
          ▼
┌───────────────────────────────┐
│ PlaceholderCreation           │
│ CreateInstance()              │
└───────────────────────────────┘
```

---

## Legacy Implementatie

Er bestaat ook een legacy versie in `Editor/Gui/Graph/Legacy/Interaction/SymbolBrowser.cs`. Deze heeft dezelfde basis functionaliteit maar met een andere UI layout inclusief:
- Preset panel
- Description panel
- Andere styling

De moderne MagGraph implementatie is de actieve versie.