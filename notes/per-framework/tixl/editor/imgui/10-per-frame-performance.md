# Chapter 10: Per-Frame Performance Discipline - Paying Only for What Changed

> *An immediate-mode editor runs every line of its UI code sixty times a second, so a habit that costs nothing in a dialog costs a stutter in a tree.*

---

## The Problem: The Same Code, Sixty Times a Second

Dear ImGui has no retained widget tree. Every frame, your code walks the whole UI again: it loops over symbols, formats labels, builds tooltips and asks "was this clicked?". In a menu that opens once a minute, an extra string allocation is invisible. In a symbol tree that redraws every frame for every expanded namespace, the same allocation happens thousands of times a second, and the garbage collector eventually pauses the frame to clean up. The user sees a hitch and has no idea why.

tixl's editor has three layers of defence against this, and they do not always agree. There are **written rules** (no allocations, no LINQ, no closures in per-frame code). There is **practice** (helpers and caches that make the rules easy to follow, and a few places that break them). And there is **diagnostics** (tools that tell you when a frame went wrong anyway). This chapter covers all three, plus a fourth idea that matters more than any rule: **work avoidance**, meaning the cheapest frame is the one that skips the work entirely.

The MagGraph canvas has its own optimizations (caching, culling, layout reuse), covered in [MagGraph performance](../maggraph/18-performance.md). This chapter does not repeat them. It covers the editor-wide discipline: what the rules say, where they hold, where they bend, and how to translate the whole package for a Rust editor on dear-imgui-rs.

**Mental model: a restaurant kitchen during service.** Prep work (chopping, stocks, sauces) happens before service, once. During service, the line cooks only assemble and plate. A cook who stops to chop onions for each order is the allocation in your draw loop. A good kitchen also has a ticket rail and a head chef who notices when a plate is late; that is your frame-time bar and your watchdog. And the best dish is the one already plated: a cached result that you only remake when an ingredient changes.

> **Scope note.** Paths are relative to `visual-programming/tixl/`. Related chapters: [02 Input Routing and Focus](02-input-routing-and-focus.md) introduced `FrameStats` as a one-frame flag exchange; [04 Retained State](04-retained-state.md) covers the change counters that drive cache invalidation; [08 Frame Loop, Fonts and DPI](08-frame-loop-fonts-and-dpi.md) covers the loop these rules live inside; and [11 Stated Rules vs. Code](11-stated-rules-vs-code.md) checks every written UI rule against the code.

---

## What Do the Written Rules Actually Say?

The rules live in two documents, and they have different jobs.

`.agentic/AGENT_INSTRUCTIONS.md:29-37`, titled "Realtime Performance Constraints (Critical)", tells per-frame methods to "Avoid heap allocations", "Avoid LINQ" and "Prefer explicit loops and reusable buffers". It then carves out an exception: "Allocations are acceptable for explicit user-triggered actions." At `:39` comes the counterweight: "Don't speculatively micro-optimise cold paths... reach for the optimised form only when a measurement says to."

Three more places apply the rules to concrete situations:

- `:152` says the editor is "rendered every frame at the output refresh rate", and names `MagGraphCanvas.DrawNode.cs` as the style reference, not the Legacy code.
- `:270-273` covers `ContextMenuForItem`, whose body "runs every frame". The instruction is to pass a static method group, because "a capturing lambda allocates a closure each frame".
- `:364-369`, "Performance in draw methods", is the checklist: no allocations, no LINQ, no closures, no `params` arrays; reuse static buffers (`static Vector2[] _points = new Vector2[5]`); pass hot data by `ref`; build tooltips only inside `if (isHovered)`; use one global time source for pulsing.

The second document, `.agentic/Reviews/FEATURE_REVIEW.md:90-106` ("Realtime performance"), is the reviewer's version. It lists what to flag: `new`, LINQ, string interpolation, `foreach` over non-struct enumerators, closures, boxing, `params`, `ToString`. Tolerance is "zero" for the graph canvas, timeline, output windows, operator updates and audio callbacks. Dialogs and settings drawn only while open are exempt. It also flags loops that grow with data, string lookups, per-frame `Array.Sort`, and locks around more than a few field copies.

### The Key Idea: Hotness Is Scoped in Review, Not in Code

Notice the first instruction in that review section (`FEATURE_REVIEW.md:92`): "identify which methods run per frame... check only those". The rules never mark a method as hot. No attribute, no naming convention, no analyzer. A reviewer has to work out which code runs per frame by reading the call graph. That is a cheap policy, and it explains the practice we are about to see: the rule is applied where someone thought about hotness, and skipped elsewhere.

Also notice what the rule text does not say. `stackalloc` and pooling appear nowhere in it. Those techniques show up in the code anyway, which is our first hint that practice runs ahead of the written rule.

---

## How Does tixl Follow the Rules in Practice?

The rules are easy to state and tedious to follow, so tixl supplies helpers. Five patterns recur.

### Pattern 1: Format Text Without Allocating

Every label you hand to ImGui is a string, and a string built with `$"..."` is a heap object. `Editor/Gui/Styling/SpanFormat.cs:11-36` is an allocation-free interpolated-string handler. Its doc comment states the motivation: generating strings for ImGui "causes a lot of GC allocations". Here is the usage shape, with a stack buffer standing in for the heap string:

```csharp
Span<char> buffer = stackalloc char[32];
buffer.Format($"{count} Items##{id}\0");
```

The `\0` terminator is there because ImGui wants C strings. Elsewhere, `Editor/Gui/UiHelpers/StallOverlay.cs:279-285` formats into a static `char[16]` via `TryFormat`. Counting hits, about 33 `stackalloc`/`ArrayPool` uses appear in 17 files under `Editor/Gui`, mostly in the OutputSetup views.

### Pattern 2: Cache What Does Not Change

Some values are expensive to compute and rarely change. `Editor/Gui/UiHelpers/EnumCache.cs:9-30,48-73` caches `Enum.GetNames` and `Enum.GetValues` per type. A comment at `Editor/Gui/Interaction/WithCurves/CurveEditing.cs:566-567` explains a parallel-array approach "instead of Enum.GetValues + ToString(): enum-to-string allocates". `Editor/Gui/MagGraph/Model/MagGraphMissingItem.cs:15` caches a name because "the canvas draws it every frame". `Editor/Gui/OutputUi/MeshGeometryOutputUi.cs:193` formats rows once per geometry change, and the OutputSetup views (`SetupOutputView.Picking.cs:251,267`, `SetupOutputView.Board.cs:2092`) rebuild labels only on a "structure tick".

### Pattern 3: Pass Delegates That Are Already Built

The closure rule from `AGENT_INSTRUCTIONS.md:270-273` shows up as static method groups and cached `Action` fields: `Editor/Gui/Windows/OutputSetup/OutputSetupModeView.cs:140,471` and `Editor/Gui/Windows/OperatorHelp.cs:377`.

### Pattern 4: Remember Failure So You Do Not Retry It Every Frame

This one is easy to miss. If a per-frame caller asks for something that fails, the naive code retries on the next frame, and the next. `Editor/Gui/Audio/AudioImageFactory.cs:23,60,96` keeps a failure memo so callers do not respawn tasks or re-log. `Editor/Gui/Help/HelpIndex.cs:99` sets `_loaded` first, so a parse failure does not retry every frame. `Editor/Gui/Hub/ProjectsPanel.cs:427` puts the rule in a comment: the code "must not do per-frame IO or string building".

### Pattern 5: Fix It When You Notice

`Editor/Gui/Windows/SymbolLib/SymbolLibrary.cs:780` carries a deliberate fix with its own comment: "Iterate instead of GetSelectedChildUis().ToList() - this runs every frame." Someone saw the cost and removed it. That makes the next section all the more interesting.

---

## Do the Written Rules Survive Contact with the Code?

> | Stated rule | What the code does |
> |-------------|--------------------|
> | "Avoid LINQ" in per-frame methods (`AGENT_INSTRUCTIONS.md:29-37`) | About 186 `.Where/.Select/.ToList/.OrderBy` calls in 72 files under `Editor/Gui` (excluding Legacy). Most are in dialogs and user-triggered paths (MagGraph, Interaction, `OutputSetup/SetupActions.cs` with 21, `SymbolLibrary.cs` with 7). A few are in per-frame paths. |
> | "Zero" allocation tolerance for hot windows (`FEATURE_REVIEW.md:90-106`) | Aspirational. `$"..."` appears about 122 times in 44 files under MagGraph/Ui, OpUis, TimeLine and SymbolLib. Per-frame share is unaudited. |
> | Hotness is something you check in review (`FEATURE_REVIEW.md:92`) | Nothing in code marks hotness. Compliance depends on a reviewer tracing the call graph. |
> | Rules never mention `stackalloc` or pooling | The code uses both (about 33 hits) and ships a dedicated allocation-free formatter (`SpanFormat.cs`). Practice is ahead of the rule. |
> | Worst violation | `SymbolLibrary.cs:553-555`: an O(n^2) `ToList()` inside the tree draw loop (details below). |

The rules are real and mostly respected, but they are aspirational at the edges. That is not a criticism: the rule text itself asks for measurement before micro-optimizing, and it exempts user-triggered code. The useful question is which violations sit on the per-frame path.

### Trace: Where Does the Worst Violation Hide?

The symbol tree draws every frame, once per expanded namespace. Inside that draw, `SymbolLibrary.cs:553-555` reads:

```csharp
for (var index = 0; index < subtree.Symbols.ToList().Count; index++)
{
    var symbol = subtree.Symbols.ToList()[index];
```

Here is why this matters. A C# `for` loop re-evaluates its condition on every iteration, so `ToList()` runs once for the `.Count` check and again for the indexer. Each `ToList()` copies all n symbols. Two copies per symbol across n symbols is O(n^2) element copies per namespace per frame, plus two short-lived lists per iteration for the garbage collector. A comment justifies it as a defence against modification during iteration: if a callback adds or removes a symbol mid-loop, iterating the original collection would throw.

The concern is legitimate, but the cure is oversized. A single snapshot before the loop gives the same safety at O(n). Even better, collect the actions and apply them after the loop (see the Rust section, where the borrow checker forces this design anyway).

### Two Smaller Violations, and One Good Pattern

- `Editor/Gui/Windows/TimeLine/TimeLineCanvas.cs:402` calls `VisibleComponentMask.Keys.ToList()` and then `RemoveWhere` with a lambda (`:397`). A comment says "small alloc only when a hash was actually removed". How often that happens per frame is unverified.
- `Editor/Gui/AppMenuBar.cs:528` calls `GetSelectedChildUis().ToList()`. Whether it is gated to run only on user action is unverified.
- The good pattern: `Editor/Gui/Windows/AssetLib/AssetLibrary.cs:75-79` runs `.Where().OrderBy().ToList()`, which is exactly what the rules forbid, but gates it behind `needsUpdate` (`:59-65`). That flag combines a file-watcher counter, a composition change and a filter/search change. The LINQ runs only when an input changed. This is work avoidance beating the allocation rule: the code is rule-violating on paper and cheap in practice.

The AssetLibrary example is the real lesson of this chapter: it is the dish already plated. A rule says "do not allocate every frame". A cache says "do not do the work every frame". The second is stronger.

---

## How Does tixl Skip Work Entirely?

Allocation-free code still costs time if it does unnecessary work. tixl uses five skipping techniques. Think of them as the kitchen's ways of not cooking a dish nobody ordered.

### Hidden and Collapsed Windows Do No Work

`Window.cs:67` returns early when `!Visible`. `Window.cs:96-109` runs the content only when `Begin` returns true, so a collapsed window or a docked window on a background tab skips its content code. Because every window derives from this base class, the saving applies to the whole editor without each window opting in.

### Long Lists: Clipper vs. Manual Skip

ImGui's list clipper asks you to draw only the rows currently on screen. tixl uses it at four sites: `Editor/Gui/Windows/ConsoleLogWindow.cs:103-118`, `Editor/Gui/Dialog/SearchDialog.cs:117`, `MeshGeometryOutputUi.cs:106` and `Editor/Gui/MagGraph/Interaction/PlaceHolderUi.cs:402`. All use the unsafe `ImGuiListClipperPtr`. The symbol and asset libraries do not use it.

Those two libraries use a manual alternative instead, an `IsRectVisible` check per row. `SymbolLibrary.cs:848-856` skips off-screen rows by emitting a same-height `Dummy`, which keeps the scroll extents correct. `AssetLibrary.Draw.cs:589-591` does the same. The catch: this still loops over all n items every frame. It saves the drawing and the widget cost, but it is O(n) in the loop itself. A true clipper makes the loop O(visible). `IsRectVisible` also appears about 21 times in 18 files outside MagGraph, for example `Editor/Gui/TableView/TableView.cs:88`, `Editor/Gui/OpUis/OpUi.cs:46` and `Editor/Gui/OutputUi/DataSetViewCanvas.cs:516`.

### Spread Expensive Work Across Frames

Some tasks are too heavy for one frame, so tixl rations them. `Editor/Gui/Interaction/Variations/VariationThumbnailRenderer.cs:14` renders one thumbnail per frame. `Editor/Gui/Help/VideoResourceList.cs:293` shows one tooltip per frame. A comment at `Editor/Gui/AppMenuBar.cs:143-163` explains why this matters: resource paging per frame "can cost tens of milliseconds and looks like slow rendering". Interestingly, no `frame % N` style UI throttling was found. Rationing is by count of work items, not by a frame-modulo timer.

### Recompute on Change, Dedupe by Frame

`Editor/Gui/Windows/SnapshotControlView.cs:54,1225` recomputes on change. `Editor/UiModel/Selection/NodeSelection.cs:325` dedupes by `GetFrameCount`, so repeated calls within one frame do the work once. These are the same idea at two scales: the dirty flag says "something changed since last time", the frame count says "I already did this in this frame".

### Strings: Prefer the Cheap Overload

`TextUnformatted` (no printf-style format parsing) is the default in `CustomComponents` and `FormInputs`. Together with `SpanFormat`, these account for about 273 uses in 101 files. A related comment at `Editor/Gui/MagGraph/Model/MagGraphItem.cs:225` warns that "Using an Enumerable interface here is bad, because it creates a lot of allocations".

---

## What Tells You a Frame Went Wrong?

Rules tell you what to avoid, but you also need to know when it happened anyway. tixl has four diagnostic tools, from always-on to opt-in.

### FrameStats: A Double-Buffered Exchange, Not a Timer

Despite the name, `Editor/Gui/FrameStats.cs:12-20,64-103` does not measure time. It is a per-frame state exchange (introduced in [chapter 02](02-input-routing-and-focus.md)). `CompleteFrame` swaps `Current` and `Last`, then clears. Flags such as `IsModalDialogOpen` and `UiColorsChanged` live there, along with reusable `HashSet<Guid>` instances `HoveredIds` and `CrossHighlightedIds` (`:76-77`). Writers add to `Current` and readers query `Last`, which means readers are one frame late. A comment at `:48-49` calls this imperceptible. Change counters `WindowLayoutChanged` and `SelectionChanged` (`:17-19`) and a `HasChanged` helper (`:25`) feed the cache-invalidation pattern from [chapter 04](04-retained-state.md).

Two performance points. The hash sets are reused rather than allocated per frame, so the exchange costs nothing in steady state. And the change counters are what make "recompute on change" cheap: compare a counter, not a data structure.

### The Frame-Time Bar

`Editor/Gui/Windows/Analyze/Metrics.cs:41-110` draws a 100 px bar into the app menu bar (`AppMenuBar.cs:69`), so it is always visible. It shows a delta-time bar and a CPU-frame-time bar, a decaying peak marker and a refresh-period marker. CPU time is measured with a `Stopwatch` (`:28-38`). Clicking the bar toggles the `PerformanceWindow` (`:53`), whose data comes from `Core/Stats/PerformanceMetrics.cs` (`WindowSize = 400`, linear and log10 histogram buckets, `:17-50`). This is the ticket rail: a bar that is always on screen beats a profiler you have to remember to open.

### Opt-In Profiling

`Editor/App/Profiling.cs` is deliberately gated. `EnableFrameProfiling` records a `__Stats/_ProcessFrame` region per frame into `DebugDataRecording` (`:12-16`, `28-35`). `EnableGCProfiling` records heap size after GC per generation, and only when the value changed (`:18-24`, `43-53`). The settings text at `Editor/Gui/Windows/SettingsWindow.cs:499-501` gives the purpose: "correlation between frame drops and GC activity". Events are trimmed in chunks of 6000 above 36000 (`:37`, `77-79`). Even the profiler follows the rules: the `$"{duration * 1000:0ms}"` string at `:35` allocates only when profiling is on.

### The Stall Watchdog

The most unusual tool is the head chef who walks in when the line has frozen: `Editor/App/StallWatchdog.cs`. If the main thread freezes, ImGui cannot draw anything, so something outside the main thread has to tell the user. Here is how it works:

1. The main thread writes a heartbeat at frame start and before rendering (`:79-97`).
2. A background thread (AboveNormal priority, 50 ms poll, `:299`) declares a stall when the heartbeat is older than `StallThresholdSeconds = 0.15` (`:291`).
3. Before declaring, it checks that the window is not minimized and that `SendMessageTimeout(WM_NULL, 100ms)` fails (`:157-176`). That distinguishes a hung app from a modal drag loop.
4. It presents the last captured UI frame plus a `StallOverlay` at about 30 fps (`OverlayFrameMilliseconds = 33`).
5. Recovery requires frames under 0.1 s for 0.25 s (`:294-296`), so one fast frame does not flicker the overlay away.

The watchdog never touches ImGui, the deferred context or `PresentLock` (`:29-35`), and it skips presenting while its fade is under 0.1 (`:138-140`).

Because it cannot call ImGui from a background thread (`StallOverlay.cs:14-16`), the overlay builds its own geometry from a snapshot of glyph metrics for chars 32-255 (`:158-172`, `300-301`), into a static `ImDrawVert[6*1024]` (`:156`). It shows a title from `MainThreadActivity`, elapsed seconds, a progress bar that asymptotes at 0.97 (`:125`) and the last log line (`:131-140`), with a 1 s fade-in (`:303`).

---

## Gotchas: What Could Still Mislead You

> Labels: **verified** means confirmed in the traced source. **Unverified** means the frequency or gating was not checked.

1. **The O(n^2) loop is verified; its practical cost is unverified.** The `ToList()` pair at `SymbolLibrary.cs:553-555` is in source. How slow it feels depends on symbol count per namespace, which we did not measure.
2. **TimeLineCanvas and AppMenuBar `ToList()` calls are unverified.** Whether `TimeLineCanvas.cs:402` removes hashes often, and whether `AppMenuBar.cs:528` is gated, is not established.
3. **The `$"..."` count is not a per-frame count.** The roughly 122 interpolations across 44 files include cold code. Do not read it as 122 per-frame allocations.
4. **Manual `IsRectVisible` skipping is still O(n).** Looks like clipping, loops like no clipping.
5. **One-frame-late reads.** Reading `FrameStats.Last` means hover and highlight sets lag a frame. The code notes it as imperceptible; treat that as a claim, not a measurement.
6. **A watchdog overlay is a different render path.** Because it cannot use ImGui, its text comes from a glyph snapshot of chars 32-255. Text outside that range will not render there (inferred, not verified).
7. **Failure memos need an escape hatch.** Setting `_loaded` first (`HelpIndex.cs:99`) stops retry storms, but it also means a transient failure sticks until something resets it (inferred, not verified).

---

## What Changes When You Rebuild This in Rust with dear-imgui-rs?

Most of tixl's rules exist because of the .NET garbage collector. Rust has no GC, so some of them vanish, some change shape and a few get sharper. Let's sort them honestly.

### What Does Not Carry Over

- **Iterator adaptors do not allocate.** `.iter().filter().map()` compiles to a plain loop with no heap use. The "avoid LINQ" rule has no direct Rust equivalent. What you must avoid is the terminal step that materialises a collection.
- **Non-capturing closures do not allocate.** A closure that captures nothing is a zero-sized value. A closure that captures by reference is a small stack struct. There is no per-frame "closure object" cost like the one `AGENT_INSTRUCTIONS.md:270-273` warns about. Boxing a closure (`Box<dyn Fn>`) is what allocates.
- **No GC pause.** There is no collector to schedule a hitch, so "allocation causes frame drops" becomes "allocation costs allocator time", which is usually smaller and steadier. The rule is weaker, not gone.

### What Does Carry Over

- **`format!`, `to_string()` and `collect()` do allocate.** These are the Rust equivalents of `$"..."`, `ToString()` and `ToList()`. In draw code, each one is a heap allocation per call.
- **`Vec` growth and `String` growth allocate.** Pushing past capacity reallocates.
- **O(n) per frame on large data is still O(n).** The `ToList()` O(n^2) trap translates as "cloning a `Vec` inside a loop".
- **Work avoidance carries over completely.** It never depended on the runtime.

### What dear-imgui-rs 0.8.0 Does for You

Checked against the 0.8.0 source: `ui.text` (`src/ui.rs:119-129`) calls `igTextUnformatted(ptr, ptr+len)`. There is no NUL terminator and no format parsing, so it is the cheapest text path. Other widgets (`text_colored`, `text_wrapped`, button labels) go through `scratch_txt` (`src/ui.rs:70-113`), a reused buffer that copies the label and NUL-terminates it. For a `&str` label this costs a memcpy and no heap allocation in steady state. So prefer `&str`, and avoid `format!` per widget per frame.

The practical alternative is to write into a reused `String` field. This sketch clears the buffer each frame; the capacity survives, so after warm-up the formatting allocates nothing.

```rust
use std::fmt::Write;

struct StatusLine { buf: String }

impl StatusLine {
    fn draw(&mut self, ui: &Ui, count: usize) {
        self.buf.clear();                       // keeps capacity
        let _ = write!(self.buf, "{count} items"); // no new allocation after warm-up
        ui.text(&self.buf);
    }
}
```

### Rust Recommendations

**1. Dirty-counter caching.** tixl's `needsUpdate` in `AssetLibrary.cs:59-65` becomes a generation number. Every mutation bumps a `u64`; a cache stores the generation it was built from and rebuilds only on mismatch. This pairs with the counters in [chapter 04](04-retained-state.md).

```rust
struct Cached<T> { built_at: u64, value: T }

fn visible_assets<'a>(cache: &'a mut Cached<Vec<AssetId>>, lib: &Library, filter: &str) -> &'a [AssetId] {
    let gen = lib.generation().wrapping_add(filter_hash(filter));
    if cache.built_at != gen {
        cache.value.clear();
        cache.value.extend(lib.assets().filter(|a| a.matches(filter)).map(|a| a.id));
        cache.built_at = gen;
    }
    &cache.value
}
```

Here the `extend` with iterator adaptors is fine: it runs only on change and reuses the existing `Vec` capacity. Mixing the filter hash into the generation is a simplification for the sketch; use whatever combination of inputs your cache depends on.

**2. Double-buffered hover sets.** The `FrameStats` exchange maps to `std::mem::swap` plus `clear()`, as in [chapter 02](02-input-routing-and-focus.md). Swapping keeps both sets' capacity, so steady state allocates nothing.

```rust
fn end_frame(&mut self) {
    std::mem::swap(&mut self.hovered_current, &mut self.hovered_last);
    self.hovered_current.clear();
}
```

**3. Scratch fields, cleared per frame.** Keep `Vec` and `String` buffers as struct fields, call `clear()` at the top of the draw, and let capacity survive. This is the Rust form of tixl's static `Vector2[]` buffers, without the static.

**4. Deferred actions.** Instead of tixl's defensive `ToList()`, collect commands during the loop and apply them afterward. This fixes the "modified during iteration" worry and the borrow checker demands it anyway: you cannot mutate the library while iterating it.

```rust
let mut commands: Vec<Command> = std::mem::take(&mut self.command_scratch);
for symbol in tree.symbols() {
    if row(ui, symbol).delete_clicked { commands.push(Command::Delete(symbol.id)); }
}
for c in commands.drain(..) { app.apply(c); }
self.command_scratch = commands; // hand the buffer back, capacity intact
```

**5. Use the list clipper for flat lists.** Checked against `src/list_clipper.rs`: `ListClipper::new(items_count: i32)`, `.items_height(f32)` (default -1 measures the first row) and `.begin(&Ui)` returning a `ListClipperToken`. The token offers `step()`, `display_start()`, `display_end()` and `iter()`, which yields visible indices and is the recommended form. Rows must have a fixed height (doc `:20-22`). Begin and drop create and destroy a native clipper, one small native allocation per clipper per frame.

```rust
for i in ListClipper::new(n as i32).items_height(h).begin(ui).iter() {
    row(i as usize);
}
```

Trees are not flat lists. For a symbol tree, flatten the visible rows into a `Vec` rebuilt on change (dirty counter again), then clip that. That avoids tixl's manual `IsRectVisible` loop, which stays O(n).

**6. A watchdog thread with an atomic heartbeat.** The main thread stores a timestamp into an `AtomicU64` at frame start; a background thread polls and flags a stall past a threshold. The responsiveness probe tixl uses (`SendMessageTimeout`) is Windows-specific, so hide it behind a platform trait and degrade to "heartbeat only" elsewhere. Keep the same discipline: the watchdog never touches ImGui, and recovery uses hysteresis.

**7. An always-visible frame-time bar.** Copy the idea, not the code: a small bar in the menu bar that shows frame time and a decaying peak, and opens a detail window on click.

**8. Enforcement over prose.** tixl's rules are text, and the audit above shows how far text drifts. In Rust you can enforce a rule mechanically: in debug builds, install a counting global allocator and show allocations per frame in the HUD, or assert it is zero inside a marked hot scope. This also solves the "hotness lives only in review" problem, because the marked scope is explicit.

```rust
// Debug builds only: wrap the system allocator and count calls.
static ALLOCS: AtomicUsize = AtomicUsize::new(0);

struct Counting;
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 { ALLOCS.fetch_add(1, Relaxed); System.alloc(l) }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) { System.dealloc(p, l) }
}
```

Read `ALLOCS` at the start and end of each frame (or of a hot scope) and show the difference. Note the counter is process-wide, so allocations on other threads inflate it; for a strict assert, scope it to the UI thread or accept some noise.

### What to Improve Over tixl

- **Make hotness explicit.** A marked hot scope plus the allocation counter replaces "reviewers will work out which methods run per frame".
- **Prefer a clipper to manual skipping.** Flatten trees, clip the flat list, and keep the loop O(visible).
- **Keep the measurement clause.** tixl's rule at `:39` is wise: do not rewrite cold code. The allocation HUD gives you the measurement the rule asks for.

---

## Summary

- tixl writes a strict per-frame rule (no allocations, no LINQ, no closures) and scopes "per frame" by review, not by code. Compliance is strong where someone thought about hotness and weak elsewhere.
- Practice runs ahead of the rules: an allocation-free formatter, caches, cached delegates and failure memos. The worst violation is the O(n^2) `ToList()` in the symbol tree draw.
- Work avoidance beats allocation avoidance: hidden windows skip content, change counters gate rebuilds, expensive jobs are rationed per frame.
- Diagnostics are layered: a double-buffered `FrameStats`, an always-visible frame-time bar, opt-in profiling and a stall watchdog on its own thread.
- In Rust, iterator adaptors and non-capturing closures are free, while `format!`, `to_string()` and `collect()` allocate. Use dirty counters, scratch buffers, deferred commands, the list clipper and a debug allocation counter.

## Next Steps

For the frame loop these rules run inside, see [chapter 08](08-frame-loop-fonts-and-dpi.md). For the change counters behind cache invalidation, see [chapter 04](04-retained-state.md), and for the one-frame flag exchange see [chapter 02](02-input-routing-and-focus.md). For graph-specific optimizations, see [MagGraph performance](../maggraph/18-performance.md). To see how these rules fare against the code, continue to [chapter 11](11-stated-rules-vs-code.md), which audits every written UI rule.
