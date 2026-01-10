# Graph Execution: From Operators to Commands

> How Werkkzeug4 transforms a flexible editor graph into an optimized execution sequence

---

## The Problem: Two Kitchens, Two Needs

Every visual programming tool faces the same dilemma. The editor wants to be a creative space: flexible connections, instant undo, lazy evaluation so the UI stays responsive. But the renderer wants to be a factory floor: linear memory access, minimal branching, predictable execution. These goals conflict.

Imagine a chef reading a recipe book while cooking. They flip to page 47 for the sauce, back to page 12 for prep notes, then forward to page 89 for the finishing technique. Each page-flip wastes time. For a dinner party, you want those cross-references. For a busy restaurant, you want prep cards: flat, ordered instructions with everything resolved in advance.

Werkkzeug4 separates these concerns with a compilation step. The visual graph exists for creative exploration. When you hit "calculate," a compiler transforms that graph into a command buffer that the executor can blast through without backtracking. This is the two-tier architecture that makes complex demoscene productions possible in real-time.

The key insight is decoupling. The graph changes frequently during editing. The command buffer only changes when you explicitly recompile. You can tweak parameters in the editor while last night's commands still execute, and those edits take effect only on the next compile. This separation lets the editor be flexible without compromising runtime performance.

---

## The Mental Model: A Kitchen Brigade

Let me develop an analogy that will guide us through the entire compilation pipeline. Imagine a high-end restaurant with specialized roles.

**The Recipe Book** is your operator graph in the editor. Recipes reference each other: "For the sauce, see the demi-glace recipe. Use the stock from yesterday's batch. If serving the vegetarian option, substitute ingredient X." These cross-references are powerful for organization but terrible for service speed.

**The Head Chef** is the `wBuilder` compiler. Before service begins, the head chef walks through tonight's menu and produces prep cards for each station. They resolve all cross-references, calculate quantities, and arrange everything in the order it needs to happen.

**The Prep Cards** are `wCommand` objects. Each card is self-contained: exact quantities, no page-flipping, no decisions to make. "Dice 2 cups onion. Reduce 3 cups stock to 1 cup. Combine and simmer 10 minutes."

**The Line Cooks** are the executor. They work through the prep cards in sequence, one after another. They do not interpret recipes; they execute instructions.

**The Walk-In Cooler** is the cache system. If yesterday's demi-glace is still good, the head chef writes "grab the demi-glace from shelf 3" instead of generating instructions to make a new batch. But here is the crucial detail: yesterday's demi-glace might be wrong for today. If you made it for a different dinner party with different dietary restrictions, you need a fresh batch. The cooler must track not just what is stored, but the context in which it was made.

This context tracking is what Werkkzeug4 calls the `CallId` system, and it solves a surprisingly subtle problem. We will return to it after we trace the basic compilation flow.

---

## A Concrete Example: Compiling a Simple Graph

Let us trace exactly what happens when you calculate a three-node graph: a `Torus` mesh generator feeds into a `Transform` operator, which feeds into a `Store` that saves the result. This is the simplest interesting case.

When you press the calculate button, the document calls `wBuilder::Execute()`. The head chef starts work.

**Phase 1: Parse.** The chef walks the recipe book, building a shopping list of what needs to happen. Starting from the Store, they work backward: Store needs Transform's output. Transform needs Torus's output. Torus needs nothing. The chef creates a `wNode` for each operator, recording the dependencies.

**Phase 2: Optimize.** The chef checks the cooler. Is any of this already prepared? If yesterday's Torus output is still valid, mark "load from cache" instead of "generate fresh." The chef also inserts any needed conversions. If Transform expected a different mesh format, a silent conversion step gets added.

**Phase 3: Type Check.** The chef verifies all connections make sense. A mesh output going to a mesh input is fine. A texture output going to a mesh input triggers a search for conversion operators. No valid path means an error stops compilation.

**Phase 4: Output.** The chef writes the prep cards. Walking the dependency tree depth-first, they generate commands: first Torus, then Transform, then Store. Each command captures a snapshot of the operator's parameters at this moment.

**Phase 5: Execute.** The line cooks work through the cards. Each command runs its operator function, produces output, and optionally stores the result in the cache for next time.

The key transformation happens between Phase 1 and Phase 4. The graph with its pointers and cross-references becomes a flat array of commands. No more graph traversal during execution.

---

## Let's Trace What Happens When You Hit Calculate

Here is the heart of the compilation orchestrator. Every calculation flows through these six phases.

```cpp
wObject *wBuilder::Execute(wExecutive &exe, wOp *root)
{
  if(!Parse(root)) goto ende;      // Phase 1: Build node graph
  if(!Optimize(1)) goto ende;      // Phase 2: Insert caches, conversions
  if(!TypeCheck()) goto ende;      // Phase 3: Verify type compatibility
  SkipToSlow(honorslow);           // Phase 4: Handle slow operators

  if(Root->LoadCache)              // Fast path: result already cached
  {
    result = Root->Op->Cache;
    result->AddRef();
  }
  else
  {
    if(!Output(exe)) goto ende;    // Phase 5: Generate command list
    result = exe.Execute(progress);  // Phase 6: Execute commands
  }
  // ...
}
```

Notice the fast path in the middle. If the entire graph's result is already cached with matching context, the head chef simply grabs it from the cooler. No prep cards needed. This is why parameter tweaking feels slow the first time but instant afterward.

---

## Phase 1: Building the Shopping List

The parsing phase walks the operator graph recursively, building `wNode` intermediate representations. Think of the head chef walking through the recipe book, noting every dish that needs preparation.

The chef faces three complications. First, recipes might form loops: dish A references dish B, which references dish A. This would trap the chef in infinite recursion. The parser uses a "you are here" marker to detect cycles.

```cpp
wNode *wBuilder::ParseR(wOp *op, sInt recursion)
{
  if(op->CycleCheck != 0)
  {
    Error(op, L"cyclic connection");
    return 0;
  }
  op->CycleCheck++;    // Mark: currently visiting

  // ... process operator ...

  op->CycleCheck--;    // Unmark: done visiting
  return node;
}
```

Second, inputs come from multiple sources. An operator might receive inputs through physical wires drawn in the editor, through named links that reference operators elsewhere in the project, or through default values when nothing is connected. The parser merges these into a single input list.

Third, some operators are not simple transformations. Subroutine calls inject new inputs into their body. Loop operators expand into multiple iterations. The parser handles these with context stacks that we will explore shortly.

---

## Phase 2: Checking the Cooler

The optimization phase makes caching decisions. For each node, the chef asks: can I load this from storage instead of making it fresh?

The answer depends on two factors. Does a cached result exist? And was it made in the same context? This second question is surprisingly important.

```cpp
void wBuilder::OptimizeCacheR(wNode **node)
{
  wOp *op = (*node)->Op;
  if(op->Cache && op->Cache->CallId == (*node)->CallId)
  {
    // Cache hit: replace with load instruction
    *node = MakeNode(0);
    (*node)->LoadCache = 1;
    (*node)->OutType = op->Cache->Type;
  }
  else
  {
    // Cache miss: mark for storage after execution
    (*node)->StoreCache = 1;
  }
}
```

The `CallId` comparison is the crucial detail. The same operator can produce different results in different contexts. A Blur operator inside a subroutine might be called twice with different inputs. Each call needs its own cache entry.

---

## The CallId System: Context-Aware Caching

Here is where Werkkzeug4's design gets clever. Let me illustrate with a concrete scenario.

Imagine a subroutine called "ApplyEffect" that takes an image and applies a blur followed by color correction. You call ApplyEffect twice in your graph: once on the background image, once on the foreground. The Blur operator inside ApplyEffect is the same operator, but it processes different inputs each call.

A naive cache would use operator identity as the key. "I already computed this Blur operator, reuse it." But that is wrong. The first call blurred the background; the second call needs to blur the foreground. Using the cached background blur for the foreground would produce garbage.

The CallId system solves this by giving each subroutine invocation a unique identifier. When the head chef enters a subroutine to generate prep cards, they mint a new CallId and stamp every prep card inside with it. Cache lookups require matching both the operator AND the context.

Think of it like dating the demi-glace containers in the cooler. "Demi-glace for Tuesday's tasting menu" and "demi-glace for Wednesday's tasting menu" are different entries, even though the recipe is identical. The context matters.

This pattern extends naturally to loops. Each iteration gets its own CallId. A loop that runs five times produces five separate cache entries for any operator inside the loop body. The cache stays precise without operators needing to know they are inside a loop.

---

## Phase 5: Writing the Prep Cards

After optimization, the node tree must become a flat command list. The chef performs a depth-first traversal, writing prep cards for dependencies before their consumers.

```cpp
wCommand *wBuilder::OutputR(wExecutive &exe, wNode *node)
{
  wCommand **inputs = sALLOCSTACK(wCommand *, node->FakeInputCount);

  // Generate commands for all inputs first
  for(sInt i = 0; i < node->FakeInputCount; i++)
  {
    if(node->Inputs[i]->LoadCache)
    {
      // Create lightweight cache-load command
      inputs[i] = MakeCacheLoadCommand(node->Inputs[i]);
    }
    else
    {
      // Recursively generate input's command (if not already done)
      if(!node->Inputs[i]->StoreCacheDone)
        node->Inputs[i]->StoreCacheDone = OutputR(exe, node->Inputs[i]);
      inputs[i] = node->Inputs[i]->StoreCacheDone;
    }
  }

  // Now create command for this node
  wCommand *cmd = MakeCommand(exe, node->Op, inputs);
  return cmd;
}
```

The `StoreCacheDone` field handles a subtle case. In a graph, multiple consumers might share the same input. The first traversal generates the command; subsequent traversals reuse it. This prevents duplicate work when the graph is a DAG rather than a tree.

---

## Command Self-Containment: The Snapshot Principle

Each prep card must be completely self-contained. The chef copies all parameter values from the operator into the command at compilation time. This decouples execution from editing.

The copying happens in `MakeCommand`. Numeric parameters, strings, and array data all get duplicated into the command's memory pool. After compilation, you can modify the original operator however you like. The commands retain the values from when they were generated.

This snapshot principle enables a powerful workflow. During a live performance, artists can tweak parameters while the current frame renders. Only the next calculation picks up the changes. No race conditions, no torn reads, no synchronization needed.

---

## Phase 6: The Line Cooks Execute

The executor iterates through commands sequentially. For each command, it gathers inputs, runs any attached script, calls the operator function, and handles caching.

```cpp
wObject *wExecutive::Execute()
{
  sFORALL(Commands, cmd)
  {
    // Steal input reference if possible (optimization)
    if(cmd->PassInput >= 0)
    {
      wObject *in = cmd->GetInput(cmd->PassInput);
      if(in && in->RefCount == 1)
      {
        cmd->Output = in;  // Take ownership
        cmd->Inputs[cmd->PassInput]->Output = 0;
      }
    }

    // Execute the operator
    if(cmd->Code)
      (*cmd->Code)(this, cmd);

    // Store in cache if marked
    if(cmd->StoreCacheOp && allok)
    {
      cmd->StoreCacheOp->Cache = cmd->Output;
      cmd->Output->AddRef();
    }
  }

  return lastCommand->Output;
}
```

The reference-stealing optimization deserves attention. When an operator transforms its input in-place and no one else needs the input, copying wastes memory. If the input's reference count is exactly one (meaning this command is the sole owner), the executor steals the reference. The output becomes the input object itself, avoiding allocation entirely. Chains of in-place operations like Add, Multiply, and Normalize benefit dramatically.

---

## Flow Control: Subroutines and Loops

Two constructs complicate the "flat list of prep cards" model: subroutine calls and loops.

**Subroutines** inject inputs into a nested graph. When the chef encounters a Call operator, they:

1. Generate commands for the call's input arguments
2. Push the current context onto a stack
3. Set up a new context with a fresh CallId
4. Parse the subroutine body, where Input operators reference the call's arguments
5. Pop the context stack

Input operators inside the subroutine do not generate their own commands. They simply reference the command that the Call already prepared. The subroutine body executes with the injected inputs as if they were directly connected.

**Loops** unroll at compile time. A loop with count=5 becomes five copies of the body, each with a unique CallId. The loop counter becomes a script variable accessible to operator scripts inside the body. This means "iterate N times" is a compile-time decision, not a runtime one.

The unrolling approach trades compilation time for execution simplicity. The line cooks never need to branch or count. They execute prep cards straight through. For demoscene productions where compilation happens during tool loading and execution happens every frame, this trade-off makes sense.

---

## Data Flow Overview

Here is the complete journey from editor action to rendered frame:

```
User clicks Calculate
    |
    v
wBuilder::Execute()           Head chef starts work
    |
    +---> Parse()             Build node graph from operators
    |       +---> Detect cycles
    |       +---> Expand subroutines (with CallId context)
    |       +---> Expand loops (unroll iterations)
    |
    +---> Optimize()          Check the cooler
    |       +---> Mark cache loads
    |       +---> Mark cache stores
    |       +---> Insert type conversions
    |
    +---> TypeCheck()         Verify all connections
    |
    +---> Output()            Write prep cards
    |       |
    |       v
    |     Flat wCommand array
    |
    v
wExecutive::Execute()         Line cooks run commands
    |
    +---> For each command:
    |       +---> Steal input refs (optimization)
    |       +---> Run operator function
    |       +---> Store in cache if marked
    |
    v
wObject* result               Final output ready
```

---

## Key Insights

**Copy-on-Compile.** Commands capture parameter snapshots at compilation time. The editor can change while commands execute. Changes take effect only on next compile.

**Context-Aware Caching.** The CallId system distinguishes the same operator in different subroutine calls or loop iterations. Cache lookups require both operator identity and matching context.

**Reference Stealing.** When an operator is the sole consumer of its input and transforms in-place, the executor steals the input reference rather than copying. This eliminates allocations for chains of in-place operations.

**Compile-Time Unrolling.** Loops and subroutines resolve during compilation, not execution. The command buffer contains no branches or loops, just a flat sequence of operations.

---

## Rust Implications

The Werkkzeug4 architecture maps well to Rust's ownership model.

**Two-tier compilation** fits naturally. The editor owns the graph; compilation transfers ownership of parameter data to commands; execution consumes commands and produces results. Each phase has clear ownership boundaries.

**Context-aware caching** becomes a `HashMap<(OperatorId, CallContext), Arc<dyn Object>>`. The CallContext is a simple newtype around u32.

**Arena allocation** replaces the memory pool. Use `bumpalo` for command allocation. The pool reset after execution becomes dropping the arena.

**Reference stealing** becomes `Arc::try_unwrap()`. When `Arc::strong_count() == 1`, unwrap to owned data without copying.

**Error handling** uses `Result<T, CompileError>` instead of goto-based flags. The six phases chain with `?` operators.

```rust
pub fn compile(&mut self, root: &Operator) -> Result<CommandBuffer, CompileError> {
    let node = self.parse(root)?;
    let node = self.optimize(node)?;
    self.type_check(&node)?;
    self.output(node)
}
```

Avoid raw pointers (use indices or arena references), avoid global document state (pass `&mut Context` explicitly), and let `Arc<T>` handle shared ownership automatically.

---

## Files Referenced

| File | Purpose |
|------|---------|
| `altona/main/wz4lib/build.hpp` | wBuilder, wNode definitions |
| `altona/main/wz4lib/build.cpp` | Graph compilation implementation |
| `altona/main/wz4lib/doc.hpp` | wOp, wCommand, wExecutive definitions |
| `altona/main/wz4lib/doc.cpp` | Document management, execution loop |

---

## Next Steps

- See [Operator System](./operator-system.md) for how operators are defined via the .ops DSL
- See [Type System](./type-system.md) for type hierarchy and automatic conversions
- The raw code trace at `../code-traces/graph-execution.md` contains full annotated source
