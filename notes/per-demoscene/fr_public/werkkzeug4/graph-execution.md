# Graph Execution: From Operators to Commands

> How Werkkzeug4 transforms a flexible editor graph into an optimized execution sequence

---

## The Problem: Two Audiences, Two Needs

Visual programming tools face a fundamental tension. The editor wants flexibility: rich metadata for undo/redo, pointer-based graphs for easy rewiring, lazy evaluation for responsive interaction. But runtime wants speed: linear memory access, minimal branching, predictable cache behavior.

Executing the graph directly would be like reading a recipe while cooking it. You would constantly flip back and forth between pages, lose your place, and waste time. What you really want is a prep list: a flat sequence of steps with all ingredients measured out in advance.

Werkkzeug4 solves this with a compilation step. The visual graph (`wOp` operators) is transformed into a command buffer (`wCommand` sequence) that the executor can blast through without backtracking. This two-tier architecture separates concerns cleanly: the editor owns the graph, the executor owns the commands.

Think of it like compiling source code. Your C++ files (the `wOp` graph) are rich with structure, comments, and abstractions. The compiled binary (the `wCommand` buffer) is stripped down to essential instructions. You edit the source, compile when ready, and run the result. Werkkzeug4 applies this same pattern to procedural content creation.

---

## The Mental Model: Recipe Cards

Imagine a kitchen brigade preparing a complex dish. The head chef has a recipe book with interconnected recipes: "For the sauce, see page 47" or "Use the stock from step 3 of the soup recipe." These cross-references are powerful for organization but terrible for execution speed.

Before service, a sous chef transforms this into prep cards: flat, ordered instructions with everything resolved. "Dice 2 cups onion. Reduce stock to 1 cup. Combine and simmer 10 minutes." No page-flipping needed.

In Werkkzeug4:
- **The recipe book** is the `wOp` graph with its links, defaults, and named references
- **The prep cards** are `wCommand` objects with copied parameters and resolved inputs
- **The sous chef** is the `wBuilder` compiler that runs five transformation phases
- **The line cook** is the `wExecutive` that executes commands sequentially

This separation enables a critical optimization: the recipe book can be edited while the kitchen runs last night's prep cards. Only when you explicitly "recompile" do the new changes take effect.

---

## The Compilation Pipeline

When you calculate an operator in Werkkzeug4, the `wBuilder` orchestrates a six-phase pipeline. Here is the high-level flow from `altona/main/wz4lib/build.cpp:885`:

```cpp
wObject *wBuilder::Execute(wExecutive &exe, wOp *root, sBool honorslow, sBool progress)
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

Each phase has a distinct responsibility:

| Phase | Name | Input | Output | Purpose |
|-------|------|-------|--------|---------|
| 1 | Parse | `wOp` graph | `wNode` tree | Build intermediate representation |
| 2 | Optimize | `wNode` tree | Optimized tree | Insert cache loads/stores, type conversions |
| 3 | TypeCheck | Node tree | Validated tree | Verify input/output compatibility |
| 4 | SkipToSlow | Node tree | Pruned tree | Handle expensive ops during editing |
| 5 | Output | Node tree | `wCommand` list | Generate flat execution sequence |
| 6 | Execute | Command list | `wObject*` | Run the commands |

The intermediate `wNode` representation is crucial. It preserves enough structure for optimization passes while being simpler than the full `wOp` graph. After optimization, the tree is flattened into a command buffer that discards the structure entirely.

---

## Phase 1: Parsing the Graph

The parser walks the `wOp` graph recursively, building `wNode` objects. This sounds straightforward, but three complications make it interesting: cycle detection, input resolution, and flow control operators.

### Cycle Detection

A malicious or buggy graph could create cycles: A feeds B, B feeds C, C feeds A. Evaluating this would loop forever. The parser uses a `CycleCheck` counter on each operator to detect this. Here is the pattern from `build.cpp:122`:

```cpp
wNode *wBuilder::ParseR(wOp *op, sInt recursion)
{
  // Cycle detection
  if(op->CycleCheck != 0)
  {
    Error(op, L"cyclic connection");
    return 0;
  }
  op->CycleCheck++;

  // ... process operator ...

  op->CycleCheck--;
  return node;
}
```

The increment before and decrement after creates a "you are here" marker. If you encounter an operator that already has the marker, you have walked in a circle.

### Input Resolution

Operators receive inputs through multiple channels: physical connections (wires in the editor), named links (references by name), and defaults (fallback values). The parser merges these into a single input list.

```cpp
sFORALL(op->Links, info)
{
  wOp *in = 0;
  switch(info->Select)
  {
  case 0:  in = op->Inputs[index++]; break;  // Next physical input
  case 1:  in = info->Link; break;           // Named link
  case 2:  in = 0; break;                    // Explicitly empty
  default: in = op->Inputs[info->Select-3]; break;  // Choose specific
  }
  if(info->Default && !in)
  {
    in = info->Default;  // Use default operator if no input
    info->DefaultUsed = 1;
  }
  inputs.AddTail(in);
}
```

This flexibility allows operators to have optional inputs with sensible defaults, or to pull data from named stores anywhere in the project.

---

## Phase 2: Cache Optimization

The optimizer makes two key decisions for each node: should we load from cache instead of executing? And if we execute, should we store the result in cache?

Cache decisions depend on two factors: whether a cached result exists, and whether it was computed in the same "call context" (more on this shortly). Here is the logic from `build.cpp:479`:

```cpp
void wBuilder::OptimizeCacheR(wNode **node)
{
  wOp *op = (*node)->Op;
  if(op)
  {
    // Check if we can load from cache
    if(op->Cache && op->Cache->CallId == (*node)->CallId)
    {
      // Replace node with cache load
      *node = MakeNode(0);
      (*node)->Op = op;
      (*node)->LoadCache = 1;
      (*node)->OutType = op->Cache->Type;
      AllNodes.AddTail(*node);
    }
    else if(!((op->Class->Flags & wCF_PASSOUTPUT) &&
              (*node)->OutputCount == 1 && !op->ImportantOp))
    {
      // Mark for cache store after execution
      if(!Doc->IsPlayer)
        (*node)->StoreCache = 1;
    }
  }
  // ...
}
```

The `PASSOUTPUT` flag enables another optimization. When an operator simply transforms its input and has only one consumer, caching is wasteful. The consumer can steal the input reference directly.

---

## The CallId System: Context-Aware Caching

Here is where Werkkzeug4's design gets clever. A naive cache would use the operator's identity as the key: "I already computed this Blur operator, reuse it." But what if the same Blur operator appears inside a subroutine that is called twice with different inputs?

The `CallId` system solves this by giving each subroutine invocation a unique identifier. Cache lookups require both the operator identity AND a matching CallId:

```cpp
// Cache lookup respects CallId
if(op->Cache && op->Cache->CallId == (*node)->CallId)
{
  // Cache hit - same context
}
```

When entering a subroutine, the builder increments a global CallId counter and stores it in `CurrentCallId`. All nodes parsed within that call context carry this ID. The result: the same operator produces different cache entries for different call contexts.

This pattern extends to loops. Each iteration gets its own CallId, so loop bodies that depend on the iteration variable produce distinct cached results.

---

## Phase 5: Command Generation

After optimization, the node tree must become a flat command list. The `OutputR` function performs a depth-first traversal, generating commands for inputs before their consumers.

```cpp
wCommand *wBuilder::OutputR(wExecutive &exe, wNode *node)
{
  wCommand **objs = sALLOCSTACK(wCommand *, node->FakeInputCount);

  // Generate commands for all inputs first
  for(sInt i = 0; i < node->FakeInputCount; i++)
  {
    if(node->Inputs[i])
    {
      if(node->Inputs[i]->LoadCache)
      {
        // Create inline cache load command
        wCommand *lc = exe.MemPool->Alloc<wCommand>();
        lc->Init();
        lc->Output = node->Inputs[i]->Op->Cache;
        objs[i] = lc;
      }
      else
      {
        // Recursively generate input command
        if(!node->Inputs[i]->StoreCacheDone)
          node->Inputs[i]->StoreCacheDone = OutputR(exe, node->Inputs[i]);
        objs[i] = node->Inputs[i]->StoreCacheDone;
      }
    }
  }

  // Create command for this node
  wCommand *cmd = MakeCommand(exe, node->Op, objs, ...);
  return cmd;
}
```

The `StoreCacheDone` field handles DAG deduplication. When a node has multiple consumers, the first traversal generates the command and stores it. Subsequent traversals reuse the existing command rather than generating duplicates.

### Command Self-Containment

The `MakeCommand` function creates a self-contained snapshot. All parameter data is copied from the operator into the command:

```cpp
// Copy parameter data
cmd->DataCount = op->Class->ParaWords;
cmd->Data = exe.MemPool->Alloc<sU32>(cmd->DataCount);
sCopyMem(cmd->Data, op->EditData, cmd->DataCount * sizeof(sU32));

// Copy string parameters
cmd->StringCount = op->Class->ParaStrings;
cmd->Strings = exe.MemPool->Alloc<const sChar *>(cmd->StringCount);
for(sInt i = 0; i < cmd->StringCount; i++)
{
  sChar *dest = exe.MemPool->Alloc<sChar>(len + 1);
  cmd->Strings[i] = dest;
  sCopyMem(dest, op->EditString[i]->Get(), sizeof(sChar) * (len + 1));
}
```

This decouples execution from editing. You can modify operator parameters in the editor while previous commands still execute with their original values. Only the next compilation picks up the changes.

---

## Phase 6: Execution

The executor runs through the command list sequentially. For each command, it gathers inputs, runs any attached script, invokes the operator function, and manages caching.

```cpp
wObject *wExecutive::Execute(sBool progress, sBool depend)
{
  sFORALL(Commands, cmd)
  {
    // Handle PASSINPUT optimization (steal input reference)
    if(cmd->PassInput >= 0)
    {
      wObject *in = cmd->GetInput<wObject *>(cmd->PassInput);
      if(in && in->RefCount == 1)  // Only consumer
      {
        cmd->Output = in;          // Steal reference
        cmd->Inputs[cmd->PassInput]->Output = 0;  // Clear source
      }
    }

    // Execute the operator
    if(cmd->Code)
    {
      if(!(*cmd->Code)(this, cmd))  // Call operator function
        ok = 0;
      if(ok && cmd->Output)
        cmd->Output->CallId = cmd->CallId;
    }

    // Store in cache if marked
    if(cmd->StoreCacheOp && allok)
    {
      cmd->StoreCacheOp->Cache = cmd->Output;
      cmd->StoreCacheOp->CacheLRU = Doc->CacheLRU++;
      cmd->Output->AddRef();
    }
  }
  // ...
}
```

The `PASSINPUT` optimization is worth highlighting. When an operator transforms its input in-place and nobody else needs the input, copying is wasteful. If the input has `RefCount == 1`, the executor steals the reference: the output becomes the input, and the input slot is cleared. This avoids unnecessary allocations for chains of in-place operations.

---

## Flow Control: Subroutines and Loops

Werkkzeug4 supports two flow control mechanisms that complicate the simple "compile then execute" model: subroutines (Call operators) and loops.

### Subroutines

A Call operator invokes a subgraph with injected inputs. The key challenge is input injection: operators inside the subroutine need access to the call's arguments.

The solution uses a context stack. When parsing a Call, the builder:
1. Evaluates the call's input arguments
2. Pushes the current context onto a stack
3. Sets up a new context with the call's inputs available
4. Parses the subroutine body
5. Pops the context stack

Input operators inside the subroutine reference the call's inputs through the context:

```cpp
if(op->Class->Flags & wCF_INPUT)
{
  sInt n = op->EditU()[0] + 1;  // Which input to inject

  if(CallInputs == 0)
    Error(op, L"input node not in subroutine call");
  else
  {
    node = MakeNode(1, FakeInputs.GetCount());
    node->Inputs[0] = CallInputs->Inputs[n];  // Reference call's input
    node->OutType = node->Inputs[0]->OutType;
  }
}
```

### Loops

Loop operators unroll at compile time. A loop with count=5 becomes five copies of the body, each with a unique CallId and loop counter variable.

```cpp
if(inputs[i] && inputs[i]->Class->Flags & wCF_LOOP)
{
  sInt max = inputs[i]->EditU()[0];  // Loop count

  // Expand loop iterations as separate inputs
  for(sInt j = 1; j < max; j++)
  {
    inputs.AddAfter(mul, i++);
    inputloop[i] = j;  // Track iteration index
  }
}
```

The loop counter becomes a script variable, allowing operator scripts to access the iteration index and produce different results per iteration.

---

## Data Flow Visualization

Here is the complete flow from editor action to rendered frame:

```
User Action: Calculate operator in editor
    |
    v
wDocument::CalcOp(op)                    Entry point
    |
    v
wBuilder::Execute(exe, op)               Compilation orchestrator
    |
    +---> Parse(op)                      Build wNode tree
    |         |
    |         +---> Handle wCF_CALL      Subroutine expansion
    |         +---> Handle wCF_LOOP      Loop unrolling
    |
    +---> Optimize(1)                    Cache optimization
    |         |
    |         +---> OptimizeCacheR()     Load/Store decisions
    |         +---> Insert conversions   Auto type conversion
    |
    +---> TypeCheck()                    Validate compatibility
    |
    +---> Output(exe)                    Generate wCommand list
    |         |
    |         v
    |     Flat command buffer            Topologically sorted
    |
    v
wExecutive::Execute()                    Run commands
    |
    +---> For each command:
              +---> Run script (if any)
              +---> (*cmd->Code)(exe, cmd)
              +---> Store cache (if marked)
    |
    v
wObject* result                          Final output
    |
    v
wDocument::Show(result, pi)              Render to screen
```

---

## Key Insights

### Copy-on-Compile

Commands are self-contained snapshots. All parameter data is copied during compilation, decoupling execution from editing. You can modify the graph while commands execute, and the changes will only take effect on the next compile.

### Context-Aware Caching

The CallId system enables precise cache invalidation. The same operator in different subroutine calls or loop iterations gets separate cache entries. Cache lookups require both operator identity and matching context.

### Reference Stealing

The PASSINPUT/PASSOUTPUT optimizations avoid unnecessary copies. When an operator is the sole consumer of its input and transforms it in-place, the input reference is stolen rather than copied.

### LRU Eviction

The `CacheLRU` counter enables memory management. Each cache access updates the counter, providing a timestamp for least-recently-used eviction when memory pressure requires clearing caches.

---

## Rust Implications

The Werkkzeug4 architecture maps well to Rust, with some idiomatic adjustments.

### Adopt Directly

**Two-tier compilation** fits Rust's ownership model perfectly. The editor owns the graph structure; compilation transfers ownership of parameter data to commands; execution consumes commands and produces results.

**Context-aware caching** with CallIds translates to a `HashMap<(OperatorId, CallContext), CacheEntry>` pattern. The CallContext is a simple newtype wrapper around u32.

**Flat command buffers** improve cache locality. Use `Vec<Command>` rather than tree structures for the execution phase.

### Modify for Rust

**Memory pools** become arena allocators. Use `bumpalo` or `typed-arena` for command allocation. The pool reset after execution maps to dropping the arena.

**Reference stealing** becomes `Arc::try_unwrap()` or move semantics. When `Arc::strong_count() == 1`, you can unwrap to owned data without copying.

**Error handling** uses `Result<T, CompileError>` instead of goto-based error flags. The six compilation phases become a chain of `?` operators.

### Avoid

**Raw pointers everywhere**. Use indices into vectors, or arena references with lifetimes.

**Global document pointer**. Pass `&mut Context` explicitly or use dependency injection.

**Manual reference counting**. Let `Arc<T>` handle shared ownership automatically.

A sketch of the Rust architecture:

```rust
pub struct GraphCompiler<'a> {
    pool: &'a bumpalo::Bump,
    nodes: Vec<Node<'a>>,
    call_id: u32,
}

impl<'a> GraphCompiler<'a> {
    pub fn compile(&mut self, root: &Operator) -> Result<CommandBuffer<'a>, CompileError> {
        let node = self.parse(root, 0)?;
        self.optimize(&mut node)?;
        self.type_check(&node)?;
        self.output(node)
    }
}

pub struct CommandBuffer<'a> {
    commands: Vec<Command<'a>>,
}

impl<'a> CommandBuffer<'a> {
    pub fn execute(&self) -> Result<Arc<dyn Object>, ExecError> {
        let mut results: Vec<Option<Arc<dyn Object>>> = vec![None; self.commands.len()];

        for (i, cmd) in self.commands.iter().enumerate() {
            // Gather inputs, potentially stealing references
            let inputs = self.gather_inputs(cmd, &mut results);
            let output = (cmd.code)(cmd, &inputs)?;

            if let Some(cache) = cmd.cache_slot {
                cache.store(output.clone());
            }
            results[i] = Some(output);
        }

        results.pop().flatten().ok_or(ExecError::NoOutput)
    }
}
```

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

- See [Operator System](./operator-system.md) for how operators are defined and registered
- The code trace at `../code-traces/graph-execution.md` contains the full annotated source
- For texture generation operators specifically, see `../texture-generation.md` (planned)
