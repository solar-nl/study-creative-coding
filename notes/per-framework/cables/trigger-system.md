# cables.gl Trigger System: Deep Dive

> How cables.gl uses triggers for execution control and array iteration

---

## Overview

Cables.gl uses a **dual execution model** where two distinct mechanisms control how data flows through the patch:

1. **Value ports** (pull-like): Data propagates when it changes, like a spreadsheet. Values prepare state.
2. **Trigger ports** (push-like): Explicit execution signals that cascade through connected operators. Triggers execute work.

This document focuses on the trigger system: how triggers propagate, how iteration works via "trigger pumping," and what happens when things go wrong.

---

## Port Types and Triggers

Trigger ports are defined as `TYPE_FUNCTION = 1` in `core_port.js:69-77`:

```javascript
static TYPE_VALUE = 0;
static TYPE_NUMBER = 0;
static TYPE_FUNCTION = 1;      // Trigger port
static TYPE_TRIGGER = 1;       // Alias for TYPE_FUNCTION
static TYPE_OBJECT = 2;
static TYPE_TEXTURE = 2;
static TYPE_ARRAY = 3;
static TYPE_DYNAMIC = 4;
static TYPE_STRING = 5;
```

**Key insight**: `TYPE_FUNCTION` and `TYPE_TRIGGER` are the same value (1). They are aliases, not distinct types. The name "function" comes from JavaScript's function type - triggers are essentially deferred function calls.

Operators create trigger ports using convenience methods in `core_op.js`:

```javascript
// Input trigger - receives trigger signals
const exe = op.inTrigger("Execute");

// Input trigger as button - same as inTrigger, but displayed as a button
const btn = op.inTriggerButton("Reset");

// Output trigger - fires trigger signals downstream
const next = op.outTrigger("Next");
```

---

## The trigger() Method

The core execution mechanism lives in `core_port.js:764-811`. When an output trigger port calls `trigger()`, it iterates through all linked input ports and invokes their handlers:

```javascript
trigger()
{
    const linksLength = this.links.length;

    this._activity();                          // Track activity for debugging
    if (linksLength === 0) return;             // Early exit if no connections
    if (!this.#op.enabled) return;             // Skip if op is disabled

    let portTriggered = null;
    try
    {
        for (let i = 0; i < linksLength; ++i)  // Iterate ALL links
        {
            if (this.links[i].portIn)
            {
                portTriggered = this.links[i].portIn;

                // Track execution depth for debugging
                portTriggered.op.patch.pushTriggerStack(portTriggered);

                // Call the handler - THIS IS SYNCHRONOUS
                portTriggered._onTriggered();

                // Pop from stack after handler completes
                portTriggered.op.patch.popTriggerStack();
            }
            if (this.links[i]) this.links[i].activity();
        }
    }
    catch (ex)
    {
        // On error: disable the crashed op
        portTriggered.op.enabled = false;
        portTriggered.op.setUiError("crash", "op crashed, port exception");
        this.#log.error("exception in port: ", portTriggered.name);
    }
}
```

### Propagation Order: Depth-First

The `for` loop iterates links sequentially, but each `_onTriggered()` call is **synchronous**. If the triggered op fires its own output triggers, those cascade immediately before the next link is processed.

**Example**: If Op A has trigger output linked to both Op B and Op C, and Op B triggers Op D:

```
A.trigger()
  → B._onTriggered()    ← B runs first
    → D._onTriggered()  ← D runs immediately (depth-first)
  → C._onTriggered()    ← C runs after B's entire chain completes
```

This is depth-first, not breadth-first. The order depends on link iteration order, which may depend on connection order in the UI.

### The _onTriggered() Handler

When a trigger port receives a signal, `_onTriggered()` is called (`core_port.js:1037-1044`):

```javascript
_onTriggered(name)
{
    this._activity();                                    // Track activity
    this.#op.updateAnims();                              // Update any animated ports on this op
    if (this.#op.enabled && this.onTriggered)
        this.onTriggered();                              // Call user-defined handler
    if (this.#op.enabled)
        this.emitEvent("trigger", name);                 // Emit event for multi-port buttons
}
```

The `name` parameter is used for multi-port trigger buttons, allowing a single handler to know which button was pressed.

---

## The Trigger Stack

The trigger stack in `core_patch.js:105, 1345-1377` tracks execution depth:

```javascript
_triggerStack = [];

pushTriggerStack(p)
{
    this._triggerStack.push(p);
}

popTriggerStack()
{
    this._triggerStack.pop();
}

printTriggerStack()
{
    if (this._triggerStack.length == 0) return;

    console.groupCollapsed(
        "trigger port stack " +
        this._triggerStack[this._triggerStack.length - 1].op.objName +
        "." + this._triggerStack[this._triggerStack.length - 1].name
    );

    const rows = [];
    for (let i = 0; i < this._triggerStack.length; i++)
    {
        rows.push(i + ". " + this._triggerStack[i].op.objName + " " + this._triggerStack[i].name);
    }
    console.table(rows);
    console.groupEnd();
}
```

### What the Trigger Stack Does (and Does Not Do)

**The trigger stack is purely for debugging.** It does NOT:
- Prevent infinite loops (no cycle detection)
- Limit recursion depth (no max depth check)
- Block re-entrancy (same port can appear multiple times)

Protection against runaway execution comes from:
1. **`op.enabled` checks** - Disabled ops skip execution
2. **Exception handling** - Crashed ops are disabled automatically
3. **JavaScript call stack** - Eventually overflows on deep recursion

The `printTriggerStack()` method is invaluable for debugging complex patches. It shows the current execution chain when called from within an operator.

---

## Trigger-Pumped Iteration

Cables does not have built-in loop constructs like `for` or `forEach`. Instead, iteration happens by **firing triggers repeatedly with different values** - a pattern we call "trigger pumping."

### The Core Pattern

The `Repeat` operator (`Ops.Trigger.Repeat.js`) demonstrates the pattern:

```javascript
const
    exe = op.inTrigger("exe"),
    num = op.inValueInt("num", 5),
    trigger = op.outTrigger("trigger"),
    idx = op.addOutPort(new CABLES.Port(op, "index"));

exe.onTriggered = function()
{
    for (var i = Math.round(num.get()) - 1; i > -1; i--)
    {
        idx.set(i);          // 1. Set the current index VALUE
        trigger.trigger();   // 2. Fire the trigger
    }
};
```

Each iteration:
1. Set the output value (index, current element, etc.)
2. Fire the output trigger
3. Downstream ops read the current value when triggered

This inverts the typical callback pattern. Instead of passing data *into* a callback, you set data *before* triggering. Downstream ops pull the current value when they execute.

### Repeat Variants

**Repeat_v2** adds directional iteration:

```javascript
function forward()
{
    const max = Math.floor(num.get());
    for (let i = 0; i < max; i++)
    {
        idx.set(i);
        next.trigger();
    }
}

function backward()
{
    const numi = Math.floor(num.get());
    for (let i = numi - 1; i > -1; i--)
    {
        idx.set(i);
        next.trigger();
    }
}
```

**Repeat2d** iterates a 2D grid:

```javascript
exe.onTriggered = function ()
{
    for (let y = 0; y < ny; y++)
    {
        outY.set((y * m) - subY);
        for (let x = 0; x < nx; x++)
        {
            outX.set((x * m) - subX);
            idx.set(x + y * nx);
            trigger.trigger();
        }
    }
    total.set(numx.get() * numy.get());
};
```

### Array Iteration

`ArrayIteratorNumbers` iterates over array elements:

```javascript
exe.onTriggered = function ()
{
    if (!arr.get()) return;  // Empty array check

    for (let i = 0; i < arr.get().length; i++)
    {
        idx.set(i);
        val.set(arr.get()[i]);
        trigger.trigger();
    }
};
```

`Array3Iterator` handles strided arrays (e.g., XYZ triplets):

```javascript
exe.onTriggered = function ()
{
    count = 0;
    for (let i = 0, len = ar.length; i < len; i += vstep)
    {
        idx.set(count);         // Logical index
        valX.set(ar[i + 0]);    // X component
        valY.set(ar[i + 1]);    // Y component
        valZ.set(ar[i + 2]);    // Z component
        trigger.trigger();
        count++;
    }
};
```

The `vstep` defaults to 3 (for XYZ) but can be configured for other structured data.

### Stateful Iteration: TriggerCounterLoop

For state that persists across frames, `TriggerCounterLoop` maintains a counter:

```javascript
let n = Math.floor(inMinLoopValue.get());

exe.onTriggered = function ()
{
    let inMin = Math.floor(inMinLoopValue.get());
    let inMax = Math.floor(inMaxLoopValue.get());

    if (inMin < inMax)
    {
        if (n >= inMax) n = inMin;  // Wrap around
        else n++;
    }
    // ... handle reverse direction

    num.set(n);
    trigger.trigger();
};
```

Each trigger increments the counter and wraps at bounds. This enables sequential iteration across multiple frames.

---

## Nested Iteration

Nested iteration works naturally due to depth-first execution. An outer `Repeat` can trigger an inner `Repeat`:

```
MainLoop → Repeat(3) → Repeat(4) → DrawCircle
```

Execution order:
```
outer i=0
  inner j=0 → draw
  inner j=1 → draw
  inner j=2 → draw
  inner j=3 → draw
outer i=1
  inner j=0 → draw
  inner j=1 → draw
  ...
```

The inner loop completes entirely before the outer loop advances.

**Index shadowing**: If both loops output an `index` port, and you need both indices, you must route them through different paths or store them. The inner loop's index will be "current" when drawing occurs.

---

## Value-Trigger Interaction

Values and triggers work in tandem but follow different rules:

### Execution Order Within a Frame

1. **Value changes propagate first** - When a value port changes, the change flows downstream immediately via `setValue()` → `forceChange()` → linked ports
2. **Triggers fire second** - Trigger handlers execute with values already updated
3. **Animation updates** - `_onTriggered()` calls `op.updateAnims()` before the handler, ensuring animated values are current

### onChange vs onTriggered

Value ports can have `onChange` callbacks:

```javascript
const color = op.inValueColor("Color", [1, 0, 0, 1]);
color.onChange = function() {
    // Called when color value changes
    updateMaterial();
};
```

Trigger ports have `onTriggered` callbacks:

```javascript
const exe = op.inTrigger("Render");
exe.onTriggered = function() {
    // Called when trigger fires
    draw();
};
```

**Key difference**: `onChange` fires when the value changes (may be multiple times per frame). `onTriggered` fires when explicitly triggered (controlled by the graph structure).

### Gating Execution

A common pattern uses value ports to gate trigger execution:

```javascript
const exe = op.inTrigger("Execute");
const enabled = op.inValueBool("Enabled", true);
const next = op.outTrigger("Next");

exe.onTriggered = function() {
    if (enabled.get()) {
        // Only pass through trigger if enabled
        next.trigger();
    }
};
```

---

## Error Handling

### Exception in onTriggered

When an exception occurs inside a trigger handler (`core_port.js:794-810`):

```javascript
catch (ex)
{
    if (!portTriggered) return this.#log.error("unknown port error");

    // Disable the crashed op
    portTriggered.op.enabled = false;
    portTriggered.op.setUiError("crash", "op crashed, port exception");

    // Notify if in editor mode
    if (this.#op.patch.isEditorMode())
    {
        if (portTriggered.op.onError) portTriggered.op.onError(ex);
    }

    // Log the error with context
    this.#log.error("exception in port: ", portTriggered.name,
                    portTriggered.op.name, portTriggered.op.id);
    this.#log.error(ex);
}
```

**Consequences of an exception**:
1. The crashed op is **disabled** (`op.enabled = false`)
2. A UI error is set (visible in editor)
3. The exception **breaks the for loop** - remaining links from the triggering port are NOT processed
4. The trigger stack shows the execution path up to the crash

### Recovery

To recover from a crash:
1. Fix the issue in the crashed op
2. Re-enable the op (in editor: right-click → Enable)
3. The op will resume receiving triggers

### State Consistency

After a partial execution (crash mid-loop):
- Values set before the crash remain set
- Downstream ops triggered before the crash have executed
- Downstream ops after the crash point have not executed

This can leave the patch in an inconsistent state. Cache regions and explicit reset triggers help manage state recovery.

---

## Performance Considerations

### Trigger Overhead

Each `trigger()` call:
1. Iterates the links array
2. Pushes/pops the trigger stack
3. Calls `_activity()` for debugging
4. Invokes the handler function

For simple operations, this overhead is negligible. For tight loops with thousands of iterations, the overhead can become noticeable.

### Large Iteration Counts

Deeply nested or large iterations can cause:
- **JavaScript call stack overflow** - Deep recursion eventually fails
- **Frame drops** - All iterations run synchronously within one frame
- **Memory pressure** - No garbage collection during execution

Cables patches typically work around this by:
- Breaking large iterations across multiple frames
- Using GPU instancing instead of CPU iteration
- Limiting visible iteration counts in the UI

### The `changeAlways` Flag

Array iterator ops often set `changeAlways = true`:

```javascript
val.changeAlways = true;
```

This ensures the value port triggers downstream updates even if the value is the same as before. Without this, repeated identical values would be silently dropped.

---

## Comparison with Other Systems

### vs vvvv gamma's ForEach Regions

| Aspect | cables.gl | vvvv gamma |
|--------|-----------|------------|
| Iteration visibility | Implicit (trigger cascade) | Explicit (ForEach region) |
| Iteration count | First connected array's length | Splicer determines count (zip-shortest) |
| State between iterations | Explicit wiring | Accumulators (reduce/fold pattern) |
| Nested iteration | Natural (depth-first) | Nested regions |

vvvv gamma's explicit regions make iteration boundaries visible. Cables' trigger pumping is more implicit but integrates seamlessly with the dual execution model.

### vs tixl's Pull-Based Evaluation

| Aspect | cables.gl | tixl |
|--------|-----------|------|
| Execution model | Push (triggers) + pull (values) | Pull-only (lazy evaluation) |
| Dirty tracking | Per-port with `changeAlways` option | Per-slot with dirty flags |
| Iteration | Trigger pumping | Explicit loop operators |

Tixl's pure pull model skips unchanged nodes automatically. Cables' trigger model provides explicit control over execution order, important for rendering pipelines.

---

## Rust Implementation Insights

For a Rust-based visual programming system:

### Adopt the Dual Model

Separate value propagation from trigger execution:

```rust
enum Port<T> {
    Value(T),                    // Pull-based, cached
    Trigger(Box<dyn Fn(&mut Context)>), // Push-based, immediate
}
```

### Use Type-Safe Trigger Chains

Rust's ownership can enforce that triggers don't outlive their context:

```rust
impl OutputTrigger {
    fn trigger(&self, ctx: &mut EvaluationContext) {
        for link in &self.links {
            link.borrow_mut().on_triggered(ctx);
        }
    }
}
```

### Consider Async for Large Iterations

Unlike JavaScript's synchronous execution, Rust could use async to spread iterations across frames:

```rust
async fn repeat(count: usize, next: &OutputTrigger, ctx: &mut Context) {
    for i in 0..count {
        ctx.set_index(i);
        next.trigger(ctx).await;  // Could yield between iterations
    }
}
```

### Debug Stack as First-Class Feature

The trigger stack pattern is valuable for debugging. Consider building it into the execution model from the start.

---

## Related Documents

- [architecture.md](architecture.md) - Overall system structure
- [rendering-pipeline.md](rendering-pipeline.md) - Frame lifecycle and state stacks
- [api-design.md](api-design.md) - Operator definition patterns
- [list-handling-patterns.md](../../themes/node-graphs/list-handling-patterns.md) - Array handling comparison

---

## Source File Reference

| File | Key Code |
|------|----------|
| `src/core/core_port.js:764-811` | `trigger()` method |
| `src/core/core_port.js:1037-1044` | `_onTriggered()` handler |
| `src/core/core_patch.js:1345-1377` | Trigger stack implementation |
| `src/ops/base/Ops.Trigger.Repeat/` | Basic trigger pumping |
| `src/ops/base/Ops.Array.ArrayIteratorNumbers/` | Array iteration |
| `src/ops/base/Ops.Array.Array3Iterator/` | Strided iteration |

---

*Triggers are the heartbeat of a cables patch. Values set the scene; triggers make things happen.*
