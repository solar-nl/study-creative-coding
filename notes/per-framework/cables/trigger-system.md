# Cables Trigger System

> How does a visual programming system implement loops without loop nodes?

## Key Insight

> **Trigger pumping:** Instead of passing data into callbacks, cables sets output values *before* firing triggers. Downstream operators pull the current value when they execute. This inverts the typical iteration pattern and enables visual iteration through the node graph.

---

## The Iteration Problem

Most programming languages have explicit loop constructs: `for`, `while`, `forEach`. But visual programming presents a challenge. How do you draw a box that means "do this N times" when the "this" is a subgraph of connected nodes?

Some systems use special "loop regions" that visually contain the repeated portion (vvvv gamma does this). Cables takes a different approach: iteration happens by firing the same trigger repeatedly with different values. No special regions needed.

The question that guides this document: *how does trigger-based iteration actually work, and what are its implications?*

---

## Triggers vs Values: A Quick Refresher

Before diving into iteration, recall that Cables has two port types for data flow:

**Value ports** hold data and propagate changes automatically. When a slider moves, connected operators see the new value immediately.

**Trigger ports** fire explicit signals. When a trigger fires, connected operators execute in sequence. This controls *when* things happen.

The architecture document covers this dual model in depth. Here we focus on how triggers enable iteration.

---

## The Trigger Pumping Pattern

The `Repeat` operator demonstrates the core pattern. When triggered, it fires its output trigger N times, setting an index value before each:

```
┌─────────────────────────────────────────────────────────────────┐
│                         Repeat Op                                │
│                                                                 │
│   IN                              OUT                           │
│   ○ Execute (trigger)             ○ Next (trigger)              │
│   ○ Count (5)                     ○ Index (0, 1, 2, 3, 4)       │
│                                                                 │
│   When Execute fires:                                           │
│     for i = 0 to Count-1:                                       │
│       Index.set(i)      ← Set value FIRST                       │
│       Next.trigger()    ← Fire trigger SECOND                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

The order matters: value first, trigger second. When the downstream operator runs, it reads the current index value. This inverts the callback pattern where you pass data *into* the callback.

A concrete example: drawing 10 circles at different positions.

```
MainLoop → Repeat(10) → Transform(x=Index*0.1) → Circle
```

Each trigger from `Repeat` causes `Transform` to read the current index, compute a position, and draw. No loops visible in the graph - just connections.

---

## How trigger() Works

The `trigger()` method in `core_port.js` iterates through linked ports and calls each handler:

```
trigger() {
    for each linked input port:
        push onto trigger stack (for debugging)
        call port._onTriggered()
        pop from trigger stack
}
```

Two details matter for understanding iteration:

**Synchronous execution.** Each `_onTriggered()` call completes before the next link is processed. If the triggered operator fires its own triggers, those cascade immediately. This is depth-first, not breadth-first.

**Link iteration order.** Multiple links from one output are processed in array order. This order may depend on when links were created in the UI. Patches should not rely on a specific order.

---

## Depth-First Cascading

Because trigger calls are synchronous, nested iteration works naturally. Consider:

```
MainLoop → Repeat(3) → Repeat(4) → Draw
```

The outer `Repeat` fires trigger #1, which enters the inner `Repeat`, which fires 4 triggers (draw, draw, draw, draw). Only then does outer `Repeat` fire trigger #2, entering inner `Repeat` again.

```
outer=0
  inner=0 → draw
  inner=1 → draw
  inner=2 → draw
  inner=3 → draw
outer=1
  inner=0 → draw
  inner=1 → draw
  ...
```

This mirrors how nested `for` loops work in text code. The inner loop completes before the outer loop advances.

---

## Array Iteration

Iterating over arrays follows the same pattern. `ArrayIteratorNumbers` sets both an index and the current element value before each trigger:

```
┌─────────────────────────────────────────────────────────────────┐
│                    ArrayIteratorNumbers                          │
│                                                                 │
│   IN                              OUT                           │
│   ○ Execute (trigger)             ○ Next (trigger)              │
│   ○ Array ([10, 20, 30])          ○ Index (0, 1, 2)             │
│                                   ○ Value (10, 20, 30)          │
│                                                                 │
│   When Execute fires:                                           │
│     for i = 0 to Array.length-1:                                │
│       Index.set(i)                                              │
│       Value.set(Array[i])                                       │
│       Next.trigger()                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

For structured data like XYZ coordinates, `Array3Iterator` processes elements in groups of three, outputting separate X, Y, Z values per iteration.

---

## Empty Arrays and Edge Cases

What happens when you iterate an empty array? The iterator simply fires zero triggers. Downstream operators never execute. This is usually the desired behavior, but can be surprising if you expect "at least once" semantics.

What about negative counts? `Repeat` uses `Math.floor()` and clamps to zero - you cannot iterate backwards by passing -5.

What about very large counts? All iterations run synchronously within a single frame. Ten thousand iterations will block until complete, potentially causing frame drops. Cables artists typically limit iteration counts or use GPU instancing for large batches.

---

## The Trigger Stack Revisited

The trigger stack (covered in architecture.md) tracks which operators are currently executing. For iteration, two implications matter:

**Debugging.** You can call `patch.printTriggerStack()` from within an operator to see the current execution chain. Useful for understanding why an operator is running.

**No cycle protection during iteration.** The trigger stack prevents A→B→A infinite loops, but iteration *intentionally* calls the same downstream path multiple times. The stack grows with each nested level. Very deep nesting (hundreds of levels) could cause JavaScript stack overflow.

---

## Stateful Iteration Across Frames

Sometimes you want state that persists across frames. `TriggerCounterLoop` demonstrates this pattern:

```
┌─────────────────────────────────────────────────────────────────┐
│                    TriggerCounterLoop                            │
│                                                                 │
│   IN                              OUT                           │
│   ○ Trigger (fires each frame)    ○ Next (trigger)              │
│   ○ Reset                         ○ Count (0, 1, 2, 0, 1, 2...) │
│   ○ Min (0)                                                      │
│   ○ Max (3)                                                      │
│                                                                 │
│   Each trigger:                                                 │
│     Increment Count (wrap at Max)                               │
│     Output current Count                                        │
│     Fire Next                                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Connected to `MainLoop`, this cycles through 0, 1, 2, 0, 1, 2... one value per frame. Combined with arrays, you can step through elements over time rather than all at once.

---

## Error Handling During Iteration

What happens if an operator crashes mid-iteration?

1. The crashed operator is **disabled** (`op.enabled = false`)
2. The exception **breaks the loop** - remaining iterations do not run
3. The trigger stack shows where the crash occurred

This can leave state inconsistent. If iterations 0-5 set values but iteration 6 crashes, those values remain set. Recovery typically requires a reset trigger or patch reload.

---

## Performance Implications

Trigger pumping has overhead compared to a simple `for` loop:
- Each trigger call traverses the links array
- The trigger stack is modified (push/pop)
- Activity counters are updated for debugging

For most patches, this overhead is negligible. For tight loops with thousands of iterations, consider:
- GPU instancing (render many objects in one draw call)
- Breaking iteration across multiple frames
- Moving hot paths to custom JavaScript

---

## Why This Pattern?

Trigger pumping may seem roundabout compared to explicit loops. Why does Cables use it?

**Visual consistency.** All data flow looks the same - boxes connected by wires. No special "loop region" visual syntax needed.

**Composability.** Any subgraph can be iterated. Connect `Repeat` upstream, and everything downstream repeats.

**Incremental adoption.** Artists start with single-element patches, then add `Repeat` when they want multiples. The learning curve is gradual.

The trade-off is that iteration is implicit. Looking at a patch, you cannot immediately see "this runs 100 times" without tracing the trigger connections upstream.

---

## Summary

| Concept | Implementation |
|---------|----------------|
| Iteration | Fire triggers N times, setting value before each |
| Execution order | Depth-first, synchronous |
| Nested loops | Natural from trigger cascading |
| Array iteration | Value + Index outputs, one per element |
| State across frames | Counter operators with persistent variables |
| Error handling | Crash disables operator, breaks remaining iterations |

---

## Related Documents

- [architecture.md](architecture.md) - Dual execution model and trigger stack basics
- [rendering-pipeline.md](rendering-pipeline.md) - How triggers drive the render loop
- [api-design.md](api-design.md) - Writing custom operators with triggers

---

## Source Files

| File | Purpose |
|------|---------|
| `core_port.js:764-811` | `trigger()` method |
| `Ops.Trigger.Repeat/` | Basic N-times iteration |
| `Ops.Trigger.Repeat2d/` | 2D grid iteration |
| `Ops.Array.ArrayIteratorNumbers/` | Array element iteration |
| `Ops.Array.Array3Iterator/` | Strided (XYZ) iteration |
| `Ops.Trigger.TriggerCounterLoop/` | Stateful frame-by-frame counter |
