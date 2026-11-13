# Cables Graph Evaluation: Value Flow and Control Flow

> How does a node graph "run" when there is no evaluator?

## Key Insight

> **Cables has no graph evaluator.** There is no scheduler, no topological sort, no dirty-set, no per-frame "evaluate the graph" pass — `core_patch.js` has no `exec()` or `update()` method at all. Instead, two independent, eager, synchronous *push* systems run over the same ports and links: values are pushed downstream the instant they change, and triggers are pushed depth-first every frame. They never merge into a unified pass. They are reconciled by one timing invariant: value writes always finish before triggers fire.

---

## The Problem: Two Kinds of "Change"

Picture a patch that spins a cube. A slider sets the rotation *speed*. A `MainLoop` advances the rotation *angle* sixty times a second. Both are "changes" that must reach the `Transform` operator — but they have completely different rhythms.

The slider changes rarely, unpredictably, and only when a human drags it. Re-deriving the whole graph every time it moves would be wasteful, and waiting for the next frame to apply it would feel laggy. The frame clock, by contrast, changes relentlessly and on a fixed schedule — and it must drive *side effects* (draw calls) in a precise order, not just compute values.

Most dataflow engines force both rhythms through one machine: a pull-based evaluator that walks the graph on demand (TouchDesigner-style "cook"), or a push-based reactive scheduler with a dirty-set. Cables refuses to pick. It runs **two separate push mechanisms** and lets them meet at the operator. Understanding how — and why that works without any coordination layer — is the subject of this trace.

---

## The Object Model: Where the Graph Actually Lives

Before tracing execution, note one structural surprise: **the `Patch` does not own the graph's edges.**

`Patch` (`core_patch.js`) holds a flat `ops = []` array and an `_opIdCache` id→op map. That is the entire node store. But there is **no `links` array** and **no adjacency list**. A `Link` is owned only by the two `Port`s it connects — each `Port` has a `links[]` array (`core_port.js`). The graph topology is therefore *distributed*: it exists only as the union of every port's `links` array. To enumerate the whole graph you must walk every op's every port.

```
Patch
 ├── ops[]            ← every operator (the only node store)
 ├── _opIdCache{}     ← id → Op lookup
 ├── animFrameOps[]   ← ops with an onAnimFrame callback (the frame heartbeat)
 └── _triggerStack[]  ← DEBUG ONLY — see "Cycles" below

Op
 ├── portsIn[]   portsOut[]

Port  (one class for everything; type field discriminates)
 ├── type        ← TYPE_VALUE=0, TYPE_FUNCTION/TRIGGER=1, TYPE_OBJECT=2, ...
 ├── value       ← the stored data cell
 ├── links[]     ← edges THIS port participates in
 ├── onChange    ← fired on value change
 └── onTriggered ← fired on trigger
```

This absence is almost certainly *why* no graph-wide algorithm exists. cables made topological analysis structurally expensive, so it never built any — and then designed an execution model that does not need it.

Both value ports and trigger ports are instances of the **same `Port` class** (`core_port.js`), distinguished only by the integer `type` field. `Link.canLink` (`core_link.js`) forbids connecting ports of different types, so the two flows below run over **physically disjoint sets of edges** — they share the `Port`/`Link` classes but never the same wire.

---

## Flow 1: Value Flow — Eager Push on Change

When an operator produces a value, it calls `set()` on an output port. That call propagates the value *immediately and synchronously* — there is no deferral, no queue, no frame boundary.

The chain, all in `core_port.js` and `core_link.js`:

```
op produces value
  → outPort.setValue(v)                       core_port.js:385
      stores this.value = v
      forceChange()  → fires this port's own onChange / "change" event
      if PORT_DIR_OUT:
        for each link:  link.setValue()        core_port.js:432
  → Link.setValue()                            core_link.js:39
  → Link._setValue()                           core_link.js:50
        v = portOut.get()
        if portIn.get() !== v:  portIn.set(v)  ← push into downstream INPUT
  → inPort.setValue(v)
        stores this.value = v
        forceChange()  → fires the downstream op's onChange handler
```

The downstream op's `onChange` typically recomputes and calls `set()` on *its* output — re-entering the chain one level deeper. A single upstream write therefore cascades through the entire reachable value-subgraph **on the JavaScript call stack, synchronously**, the moment it happens.

Three consequences worth internalising:

- **There is no pull and no laziness.** `Port.get()` (`core_port.js:340`) just returns the stored `this.value` field. There is no dirty flag, no recompute-on-read, no cache invalidation — because there is no cache. `this.value` *is* the value, kept current by the push.
- **The one exception is animation.** An animated port lazily samples its keyframe curve inside `get()`, gated to run once per frame (`lastAnimFrame != patch.getFrameNum()`). This is the only pull-style computation anywhere in cables — the deliberate seam where the value world borrows the frame heartbeat.
- **Change suppression, not change tracking.** `setValue` skips propagation if `v !== this.value` for scalars and strings. But **texture and array ports always re-propagate** (reference equality cannot detect in-place mutation of a texture), and objects need an explicit `setRef()` to force the push. So a texture wire re-fires every downstream `onChange` every frame regardless of whether the texture changed.

```js
// core_port.js — the change-suppression check (simplified)
if (v !== this.value
    || this.changeAlways
    || this.type == Port.TYPE_TEXTURE   // reference types always re-push
    || this.type == Port.TYPE_ARRAY)
{
    this.value = v;
    this.forceChange();
    // ... then push to links if this is an output port
}
```

---

## Flow 2: Control Flow — Synchronous Depth-First Triggers

Control flow is even simpler: a trigger is just a JavaScript function call.

`Port.trigger()` (`core_port.js:764-811`) is called on an *output* trigger port. It iterates `this.links` and, for each one, calls `_onTriggered()` on the downstream input port:

```
outTriggerPort.trigger()                       core_port.js:764
  for each link (in links[] array order):
    portIn = link.portIn
    patch.pushTriggerStack(portIn)              ← debug bookkeeping only
    portIn._onTriggered()                       core_port.js:1037
        op.updateAnims()                        ← re-sample animated ports on this op
        if op.enabled && onTriggered:
            onTriggered()                       ← THE OP'S WORK RUNS HERE
    patch.popTriggerStack()
```

The triggered operator's `onTriggered` handler does its work and usually ends by calling `trigger()` on *its own* output trigger port — recursing one level deeper. The whole downstream subgraph executes **depth-first, synchronously, in a single JS call stack**, before control returns to the first `trigger()` call.

Key properties:

- **No queue, no scheduler.** `_onTriggered()` is invoked directly inside the `for` loop. Nested triggers cascade immediately.
- **Execution order = link-creation order.** The `for` loop walks `links[]` by index; that array is appended to as links are created. Order is deterministic for a fixed patch but reflects *editing history*, not graph position — re-wiring changes it. This is why cables ships an explicit `Sequence` operator: it is the only reliable way to pin ordering.
- **Triggers carry no payload.** `trigger()` ignores the port's `value` entirely. Data is moved separately, by Flow 1.

### The Per-Frame Entry Point

The root of all control flow is *not* the render loop. `core/renderloop.js` is an empty abstract base class (`exec()`, `pause()`, `resume()` are stubs). The real driver is the **`MainLoop` operator**:

```
requestAnimationFrame
  → CglRenderLoop.exec()              corelibs/cgl/cgl_renderloop.js
  → renderFrame()
      patch.updateAnims()             core_patch.js:701
        for op in patch.animFrameOps:
          op.onAnimFrame(...)         ← MainLoop registered itself here
  → MainLoop.render()                 Ops.Gl.MainLoop_v2.js
      cgl.renderStart()
      trigger.trigger()               ← THE ROOT TRIGGER — one call, whole patch
      cgl.renderEnd()
```

Because the root is an *operator*, the per-frame entry point is user-replaceable — there are several mainloop variants (`MainLoop`, `MainLoop_v2`, `ThreeMainloop`). The `Patch` itself does not orchestrate the frame; it only dispatches `onAnimFrame` to whatever ops registered for it.

---

## How the Two Flows Coexist (The Crux)

Here is the question that makes or breaks the design: **when a trigger reaches an operator, how does that operator know its value inputs are current?**

The answer: **it never checks, and it never needs to.**

The reconciling invariant is *temporal*: **value flow has already happened before the trigger arrives.** Because value propagation is eager push-on-set, an operator's value-input ports are kept continuously up to date — every upstream change (a slider drag, a mouse move, an animation key, a variable write) synchronously shoved its result all the way down into this op's input port *at the moment of the change*, entirely independently of triggers. So when `onTriggered()` runs and calls `inColor.get()`, it simply reads an already-current field.

The mental model:

| Port kind | Role | Analogy |
|-----------|------|---------|
| **Value ports** | Carry data; kept current by ambient eager push | The operator's *registers / uniform state* |
| **Trigger ports** | Carry no data; decide *when* and in *what order* ops run | The operator's *program counter* |

Coordination is **not dependency analysis**. It is purely the guarantee that value writes are synchronous and complete before any trigger fires. The `MainLoop` fires its trigger; by then every value link feeding the subtree delivered its value long ago.

The one place the two flows deliberately touch is animation: `_onTriggered()` calls `op.updateAnims()`, so a trigger *does* pump time-sampled value ports forward as it passes through. Animation is a value source that needs the frame clock, so the trigger pass gives it one.

The profiler confirms this whole picture. `core_profiler.js` instruments **trigger-port activations** — items are keyed by *port* id and the counted metric is `numTriggers`. Value propagation is not instrumented at all. The atomic unit of "evaluation" in cables is *one trigger crossing one link*; value flow is treated as free, ambient state-keeping.

---

## Cycles Are Not Prevented

A common claim about cables is that a "trigger stack" prevents A→B→A infinite recursion. **It does not.**

`Patch` keeps `_triggerStack`, and `Port.trigger()` pushes/pops onto it around each downstream call — but **nothing ever reads it to skip a re-entrant trigger.** Its only consumer is `printTriggerStack()`, a `console.table` debug dump. There is no `triggerStack.includes(op)` guard in the trigger path.

A genuine trigger cycle therefore recurses on the JS call stack until the engine throws a stack-overflow `RangeError`. The `try/catch` wrapping `trigger()`'s link loop catches it, sets `op.enabled = false` on the crashing operator, and aborts the remaining fan-out branches for that frame. So a cyclic patch will not hard-lock the browser — but that is incidental crash *recovery*, not cycle *prevention*.

Iteration operators (`Repeat`, array iterators) are safe for a different reason: they re-enter *downstream* paths, never themselves. Each downstream subtree fully completes and unwinds the stack before the next iteration begins.

---

## Trace Summary

| Question | Answer |
|----------|--------|
| Is there a graph evaluator? | No. No scheduler, sort, dirty-set, or `exec()` method on `Patch`. |
| Value flow model | Eager synchronous **push** on `set()`. No pull, no cache, no laziness (except per-frame animation sampling). |
| Control flow model | Synchronous **depth-first recursion**. A trigger is a direct JS function call. No queue. |
| Per-frame root | A `MainLoop` *operator*'s output trigger port, fired from its `onAnimFrame` callback. |
| Execution order | Link-creation order. Deterministic per patch, fragile across edits. |
| Value/control coordination | Timing invariant only: value pushes finish before triggers fire. No dependency tracking. |
| Cycle protection | None. Trigger stack is debug-only; cycles crash via stack overflow caught by `try/catch`. |
| Unit of evaluation | One trigger crossing one link (per the profiler). |

---

## Relevance to a Rust Framework (flux)

This is the inverse of a pull-based declarative dataflow engine. cables resembles tixl's command-flow split documented elsewhere in these notes — trigger ports are the imperative "execute now" baton, value ports are declarative state — but cables has *no* compound/closure mechanism and *no* render graph. It just recurses the JS call stack and relies on eager push to keep state current.

Lessons for flux:

- **The "values current before triggers fire" invariant is cheap and powerful** — but it only holds because value propagation is *fully synchronous*. In Rust, eager synchronous push across a graph means re-entrant `&mut` borrows of the graph; cables gets away with it only because JS has no borrow checker. flux cannot copy this directly; it needs either a value pass that completes before the command pass (a real two-phase split) or interior mutability at port granularity.
- **Link-creation order as execution order is a latent bug source.** flux should derive order from the graph (topological, or explicit sequencing nodes as first-class), not from edit history.
- **The lack of a graph evaluator is a feature for *immediacy* and a liability for *analysis*.** cables cannot do pass merging, cannot batch, cannot detect cycles — all things flux's render graph explicitly needs for tile-based mobile GPUs. This reinforces the hybrid direction in `MEMORY.md`: a declarative value layer (flux-style) plus a separate analyzed render graph, meeting at texture handoff points. cables shows what you give up if you skip the render graph entirely.

---

## Source Files

| File | Role in evaluation |
|------|--------------------|
| `core_patch.js` | Node store (`ops[]`), `animFrameOps[]`, `updateAnims()`, debug `_triggerStack`. **No `exec()`.** |
| `core_port.js:340` | `Port.get()` — returns stored value (+ lazy animation sampling) |
| `core_port.js:385-435` | `Port.setValue()` — eager value push to links |
| `core_port.js:764-811` | `Port.trigger()` — synchronous depth-first trigger fan-out |
| `core_port.js:1037-1044` | `Port._onTriggered()` — runs `updateAnims()` + the op's handler |
| `core_link.js:50-73` | `Link._setValue()` — value-propagation primitive |
| `core_link.js:220-255` | `Link.canLink()` — type enforcement; trigger ports cannot link to value ports |
| `core_profiler.js` | Instruments trigger-port activations — reveals the unit of evaluation |
| `core/renderloop.js` | Abstract base only; the real loop is `corelibs/cgl/cgl_renderloop.js` |
| `Ops.Gl.MainLoop_v2.js` | The per-frame root trigger |

---

## Related Documents

- [architecture.md](../architecture.md) — Three-layer architecture and the dual execution model
- [trigger-system.md](../trigger-system.md) — Trigger-pumped iteration and error handling
- [rendering-pipeline.md](../rendering-pipeline.md) — How triggers drive the render loop
- [../../tixl/rendering/graph-evaluation-engine.md](../../tixl/rendering/graph-evaluation-engine.md) — tixl's contrasting command-flow model
