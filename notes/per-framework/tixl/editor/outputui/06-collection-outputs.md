# Chapter 6: Collection Outputs

> *Lists, dictionaries, and structured data*

## Key Insight

> **Collection output's core idea:** The same data can be viewed multiple ways (grid, plot, list)—users pick the view that matches their current question, with per-view state remembering each panel's settings.

---

## The Problem: A Single Value vs. Many Values

So far, we've looked at outputs that represent a single thing - a float, a texture, a rendered scene. But what happens when an operator produces a *collection* of things? A list of 1,000 floats. A dictionary mapping names to values. A structured table of particle data.

The challenge here is fundamentally different from scalar outputs. With a single float, showing a scrolling curve makes perfect sense - you can see how it changes over time. But with 1,000 floats? A thousand tiny curves would be chaos. You need entirely different visualization strategies.

Even more interesting: the *right* visualization depends on what the user is trying to understand. Sometimes they want to see the raw numbers. Sometimes they want a plot. Sometimes they want a grid that shows the "shape" of the data at a glance.

---

## The Key Insight: View Modes

The solution is to give users **multiple ways to see the same data**.

Think of it like Google Maps. You can view a location as a street map, satellite imagery, or terrain. Same underlying data, radically different presentations depending on what you're trying to understand. Are you navigating? Use street view. Checking vegetation? Use satellite. Planning a hike? Use terrain.

Collection outputs work the same way. A list of floats might be viewed as:

- A **grid** showing individual values with visual bars
- A **plot** showing the values as a continuous line
- A **list** showing raw numbers in a scrollable column

The user picks the view that matches their current question.

---

## FloatListOutputUi: The Canonical Example

Let's trace how this works with the most common case: a `List<float>`.

### The Mental Model

Imagine you're debugging an operator that generates weights for a mesh. It outputs 500 floats, one per vertex. You might ask:

- "What's the overall distribution?" - Use plot view
- "What's the value at vertex 237?" - Use grid or list view
- "Are there any obvious outliers?" - Use plot with auto-scale

FloatListOutputUi provides all three perspectives.

### View Settings Per-View

Just like scalar outputs, collections need per-view state. But now the state is richer - it includes which view mode is active, how many columns the grid has, what the plot scale is.

```csharp
private class ViewSettings
{
    public ViewStyles ViewStyle { get; set; } = ViewStyles.Grid;
    public int ColumnCount { get; set; } = 4;
    public float PlotMin { get; set; } = 0f;
    public float PlotMax { get; set; } = 1f;
}
```

When you open the same output in two different panels, each can have its own view mode. One panel shows the grid while the other shows the plot. They're looking at the same data from different angles.

### The Grid View: Seeing the Shape of Data

The grid view is particularly clever. Each float is shown as a number, but also as a **filled bar** proportional to its value:

```text
┌─────────────────────────────────────────────────┐
│  Count: 16                    Columns: [4]      │
├─────────────────────────────────────────────────┤
│  ████ 0.750  ██ 0.250   ██████ 0.920  █ 0.100  │
│  ███ 0.500   █ 0.150    ████ 0.650    ██ 0.300 │
│  █████ 0.800 ███ 0.450  █ 0.050       ██ 0.280 │
│  ██ 0.200    ████ 0.600 ███ 0.400     █ 0.120  │
└─────────────────────────────────────────────────┘
```

Why bars? Because humans are terrible at comparing columns of numbers but excellent at comparing visual lengths. The bars let you instantly spot patterns - "the first row has higher values" or "there's one outlier near the bottom."

The column count is adjustable because different data has different natural structure. A 4x4 matrix wants 4 columns. An 8-wide audio buffer wants 8. The user can experiment to find what reveals the underlying pattern.

### The Plot View: Seeing Trends

When the data represents a continuous function (audio samples, a procedural curve, interpolation weights), the plot view shines:

```text
┌─────────────────────────────────────────────────┐
│  Min: [0.0]  Max: [1.0]                         │
├─────────────────────────────────────────────────┤
│ 1.0 ┤                                           │
│     │     ╭─╮           ╭────╮                  │
│     │    ╱   ╲    ╭────╱      ╲                 │
│     │   ╱     ╲──╱              ╲───╮           │
│     │──╱                             ╲──────    │
│ 0.0 ┤                                           │
│     └───────────────────────────────────────    │
│       0                               Count     │
└─────────────────────────────────────────────────┘
```

The choice between fixed scale and auto-scale is important. Fixed scale (0 to 1) is great when you know the expected range - you can see at a glance if values are near the boundaries. Auto-scale is better for discovery - it zooms in on whatever range the data actually occupies.

---

## Data Flow: From List to Visualization

Let's trace what happens when the editor displays a float list:

### Step 1: Type Check and Null Handling

```csharp
protected override void DrawTypedValue(ISlot slot, string viewId)
{
    if (slot is not Slot<List<float>> typedSlot)
        return;

    var list = typedSlot.Value;
    if (list == null)
    {
        ImGui.TextUnformatted("NULL");
        return;
    }
    // ...
}
```

You might wonder why we check for null explicitly. The answer is robustness - operators can legitimately produce null during initialization or error states. Showing "NULL" is better than crashing.

### Step 2: Get or Create View Settings

```csharp
if (!_viewSettings.TryGetValue(viewId, out var settings))
{
    settings = new ViewSettings();
    _viewSettings[viewId] = settings;
}
```

First time this view draws this output? Create fresh settings. Otherwise, retrieve the existing ones. This is what lets each view remember its own mode and column count.

### Step 3: Draw the Mode Selector

```csharp
private void DrawViewModeSelector(ViewSettings settings)
{
    ImGui.Text("View:");
    ImGui.SameLine();

    if (ImGui.RadioButton("Grid", settings.ViewStyle == ViewStyles.Grid))
        settings.ViewStyle = ViewStyles.Grid;

    ImGui.SameLine();
    if (ImGui.RadioButton("Plot", settings.ViewStyle == ViewStyles.Plot))
        settings.ViewStyle = ViewStyles.Plot;
}
```

Simple radio buttons at the top. Click one, the view switches. The settings object is mutated directly - no need for complex state management because it persists across frames.

### Step 4: Dispatch to the Current Mode

```csharp
switch (settings.ViewStyle)
{
    case ViewStyles.Grid:
        DrawGridView(list, settings);
        break;
    case ViewStyles.Plot:
        DrawPlotView(list, settings, autoScale: false);
        break;
    case ViewStyles.PlotAutoScale:
        DrawPlotView(list, settings, autoScale: true);
        break;
}
```

Each mode has its own drawing logic. They share the same data but render it completely differently.

---

## Beyond Simple Lists: Specialized Collection Types

### IntListOutputUi

Integers work almost identically to floats. The grid shows integer values, the plot converts to float for visualization. The key insight is that the *visualization strategy* is the same even though the data type differs.

### StringListOutputUi

Strings are different. Bars and plots don't make sense for text. Instead, we show a scrollable list with line numbers:

```csharp
for (var i = 0; i < list.Count; i++)
{
    ImGui.TextColored(UiColors.TextMuted, $"{i,4}");
    ImGui.SameLine();
    ImGui.TextUnformatted(list[i] ?? "(null)");
}
```

The line numbers serve two purposes: they show position (useful for debugging index-based logic) and they provide visual separation between entries. The null check handles the case where the list contains null strings - common when parsing external data.

---

## FloatDictOutputUi: Named Channels Over Time

Here's where things get interesting. A `Dict<float>` isn't just a collection - it's a collection of **named values that change over time**. Think of it like multiple data streams: velocity, rotation, scale, each with a name and a current value.

The key insight is that these values are most useful when you can see their *history*. A single frame's rotation might be 1.234, but that tells you nothing about whether it's oscillating, ramping up, or stable.

### Multi-Channel Plotting

FloatDictOutputUi maintains a circular buffer of history for each named channel:

```csharp
private const int HistorySize = 512;

private class ChannelData
{
    public string Name;
    public float[] History = new float[HistorySize];
    public int Offset;
    public float Min, Max, Avg;
}
```

Each frame, the new value is added to the history. The offset tracks where to write next, wrapping around when it reaches the end. This is the same circular buffer pattern used in scalar outputs, but now there's one per channel.

### Color-Coded Channels

With multiple lines on the same plot, you need to tell them apart. FloatDictOutputUi assigns colors automatically:

```csharp
private static readonly Color[] ChannelColors = new Color[10]
{
    new(1f, 0.3f, 0.3f, 1f),   // Red
    new(0.3f, 1f, 0.3f, 1f),   // Green
    new(0.3f, 0.3f, 1f, 1f),   // Blue
    // ... more colors
};
```

The legend shows which color maps to which name, plus running statistics:

```text
┌─────────────────────────────────────────────────┐
│  velocity: 0.532 (min: 0.1, max: 0.9, avg: 0.5)│
│  rotation: 1.234 (min: 0.0, max: 3.1, avg: 1.5)│
│  scale:    0.891 (min: 0.5, max: 1.0, avg: 0.7)│
└─────────────────────────────────────────────────┘
```

The statistics are computed on-the-fly from the history buffer. They answer questions like "what's the typical range of this value?" without requiring the user to stare at the plot.

---

## StructuredListOutputUi: Tables of Complex Data

Sometimes a collection contains structured objects - particles with position, velocity, and color. A simple list or plot won't capture the structure.

StructuredListOutputUi delegates to a `TableList` component that renders data as an editable table:

- Column headers from struct fields
- Editable cells for each value
- Row add/remove controls
- Sorting by column

The interesting detail is that edits flow back to the data:

```csharp
var modified = TableList.Draw(list);

if (modified)
{
    typedSlot.DirtyFlag.Invalidate();
}
```

When the user changes a cell, the slot is marked dirty. Downstream operators will recompute with the new values. This makes the output *interactive* - you can tweak data and see how it affects the rest of the graph.

---

## DataSetOutputUi: Event Timelines

DataSet is the most complex collection type. It represents **events over time** - audio beats, MIDI notes, markers. The visualization is a timeline:

```text
┌─────────────────────────────────────────────────┐
│  Time: 0.0 ─────────────── 10.0s    [Export]    │
├─────────────────────────────────────────────────┤
│  ▼ Audio                                        │
│    beat      ▲   ▲   ▲   ▲   ▲   ▲   ▲   ▲     │
│    measure   ▲           ▲           ▲          │
│  ▼ MIDI                                         │
│    note      ████    ██████    ████             │
│    velocity  ▲▲▲▲    ▲▲▲▲▲▲    ▲▲▲▲             │
│  ▶ Markers (collapsed)                          │
└─────────────────────────────────────────────────┘
```

### Two Types of Events

The key insight is that events come in two flavors:

- **Point events** (triangles): Something happened at a specific instant (a beat, a button press)
- **Interval events** (rectangles): Something with duration (a held note, a process)

DataSetViewCanvas handles both:

```csharp
private void DrawValueEvent(DataEvent evt)
{
    // Triangle marker at event time
    var pos = TimeToScreen(evt.Time);
    var color = GetChannelColor(evt.Channel);

    _drawList.AddTriangleFilled(
        pos + new Vector2(0, -5),
        pos + new Vector2(-4, 5),
        pos + new Vector2(4, 5),
        color
    );
}

private void DrawIntervalEvent(DataEvent evt)
{
    // Rectangle spanning start to end
    var start = TimeToScreen(evt.StartTime);
    var end = TimeToScreen(evt.EndTime);
    var color = GetChannelColor(evt.Channel);

    _drawList.AddRectFilled(
        new Vector2(start, _rowY),
        new Vector2(end, _rowY + RowHeight),
        color
    );
}
```

### Hierarchical Organization

Events are organized into channels, and channels can be collapsed. This is essential when you have hundreds of event types - you collapse the ones you're not interested in to focus on what matters.

The Export button lets you dump the visible events to CSV. This bridges the gap between the visual editor and external analysis tools.

---

## PointArrayOutputUi: Simple But Bounded

Not every collection needs fancy visualization. Point arrays just show coordinates:

```csharp
var displayCount = Math.Min(points.Length, MaxDisplayCount);
for (var i = 0; i < displayCount; i++)
{
    var p = points[i];
    ImGui.TextUnformatted($"[{i}] ({p.Position.X:F2}, {p.Position.Y:F2}, {p.Position.Z:F2})");
}

if (points.Length > MaxDisplayCount)
{
    ImGui.TextColored(UiColors.TextMuted,
        $"... and {points.Length - MaxDisplayCount} more");
}
```

The key detail is the `MaxDisplayCount` limit. Rendering 10,000 text lines would destroy performance. Instead, we show the first 50 and tell the user there are more. This is a pragmatic tradeoff - if they need to see all 10,000, they can export to a file.

---

## Common Patterns Across Collection Outputs

### Pattern 1: View Mode Switching

Almost every collection output offers multiple view modes. The pattern is always the same:

1. Store the current mode in per-view settings
2. Draw a mode selector (radio buttons, dropdown, etc.)
3. Switch to the appropriate drawing function

### Pattern 2: Statistics Calculation

When showing numerical data, compute and display statistics:

```csharp
private void UpdateStats(ChannelData channel)
{
    var min = float.MaxValue;
    var max = float.MinValue;
    var sum = 0f;

    foreach (var v in channel.History)
    {
        min = Math.Min(min, v);
        max = Math.Max(max, v);
        sum += v;
    }

    channel.Min = min;
    channel.Max = max;
    channel.Avg = sum / channel.History.Length;
}
```

Statistics answer questions the raw data can't: "Is this value stable?" "What's its typical range?" "Is the current value unusual?"

### Pattern 3: Bounded Display

Large collections need limits. Whether it's 50 points, 512 history samples, or a scrollable child region, the pattern is: show what fits, indicate there's more.

---

## Summary: The Collection Output Philosophy

1. **Multiple views for the same data.** Users have different questions; give them different lenses.

2. **Per-view state for each visualization.** One panel shows the grid, another shows the plot. Each remembers its own settings.

3. **Appropriate visualization for the data structure.** Floats get bars and plots. Strings get line numbers. Events get timelines. Match the visualization to what the data represents.

4. **Statistics augment raw data.** Min, max, average - these summary numbers answer questions that staring at raw data can't.

5. **Bounded display for performance.** Don't try to render 10,000 items. Show what fits, truncate the rest.

---

## What's Next

- **[Chapter 7: Command Rendering](07-command-rendering.md)** - The most complex output type: full GPU pipeline rendering
- **[Chapter 8: Extending OutputUi](08-extending-outputui.md)** - How to create your own custom output renderers
