# Code Trace: Operator Graph Execution

> Tracing the path from an operator graph (wOp) to executable output (wCommand) and frame rendering in Werkkzeug4.

## Overview

**Framework**: fr_public (altona_wz4 / Werkkzeug4)
**Operation**: Graph compilation and execution pipeline
**Files Touched**: 5 core files
**Language**: C++

Werkkzeug4 uses a sophisticated two-tier runtime architecture that separates editor-time flexibility from runtime efficiency. This document traces how an operator graph becomes executable output.

---

## The Problem: Editor Flexibility vs. Runtime Performance

In a visual programming system like Werkkzeug4, the user builds a graph of operators in an editor. But directly executing that graph structure would be inefficient:

1. **Graph overhead** - Traversing pointer-based structures every frame is slow
2. **Undo/redo needs** - The editor needs rich metadata that's wasteful at runtime
3. **Caching complexity** - Determining what needs recalculation vs. what's cached is expensive if done per-frame
4. **Flow control** - Loops, subroutines, and conditionals need special handling

Werkkzeug4 solves this with a compilation step that transforms the flexible `wOp` graph into an optimized `wCommand` sequence.

---

## User Code

In Werkkzeug4, the "user code" is the operator graph itself - created visually in the editor. The equivalent of a main() entry point is finding the "root" store operator and calculating it.

```cpp
// From doc.cpp - this is the typical entry point
wOp *rootop = FindStore(L"root");
if(rootop)
{
    wObject *result = CalcOp(rootop);
    if(result)
    {
        wPaintInfo pi;
        // ... setup paint info ...
        Show(result, pi);  // Render to screen
    }
}
```

---

## Call Stack

### 1. Entry Point: wDocument::CalcOp
**File**: `altona/main/wz4lib/doc.cpp:3317`

```cpp
wObject *wDocument::CalcOp(wOp *op, sBool honorslow)
{
  sArray<wOp *> failed;
  wOp *weak;

  // First calc all weak linked ops
  sFORALL(DirtyWeakOps, weak)
  {
    wObject *obj = Builder->Execute(*Exe, weak, honorslow, 1);
    if(!obj)
      failed.AddTail(weak);
    else
      obj->Release();
  }
  DirtyWeakOps.Clear();

  // ... handle failures ...

  // Now try to calc the real op
  wObject *res = Builder->Execute(*Exe, op, honorslow, 1);
  if(!res)
  {
    PropagateCalcError(op);
  }
  return res;
}
```

**What happens**: The document maintains a `Builder` (wBuilder) and `Exe` (wExecutive) as long-lived instances. CalcOp first handles any "weak linked" operators (operators that reference data without triggering recalculation), then delegates to `Builder->Execute()` for the main graph.

---

### 2. Graph Compilation: wBuilder::Execute
**File**: `altona/main/wz4lib/build.cpp:885`

```cpp
wObject *wBuilder::Execute(wExecutive &exe, wOp *root, sBool honorslow, sBool progress)
{
  wNode *node;
  exe.Commands.Clear();
  exe.MemPool->Reset();
  wObject *result = 0;
  TypeCheckOnly = 0;

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
    if(exe.Commands.GetCount() > 0)
      result = exe.Execute(progress);  // Phase 6: Execute commands
  }

ende:
  // Cleanup: reset BuilderNode pointers on all ops
  exe.Commands.Clear();
  sFORALL(AllNodes, node)
  {
    if(node->Op)
    {
      node->Op->BuilderNode = 0;
      node->Op->CycleCheck = 0;
    }
  }
  return result;
}
```

**What happens**: This is the main orchestrator. It runs six distinct phases:
1. **Parse** - Builds an intermediate `wNode` graph from `wOp` operators
2. **Optimize** - Inserts cache load/store points and type conversions
3. **TypeCheck** - Validates input/output type compatibility
4. **SkipToSlow** - Handles "slow" operators (expensive ops skipped during interactive editing)
5. **Output** - Generates a flat `wCommand` array from the node graph
6. **Execute** - Actually runs the commands

---

### 3. Phase 1 - Graph Parsing: wBuilder::ParseR
**File**: `altona/main/wz4lib/build.cpp:122`

```cpp
wNode *wBuilder::ParseR(wOp *op, sInt recursion)
{
  // Check for already-visited nodes (caching within subroutine context)
  if(op->BuilderNode && op->BuilderNodeCallId == CurrentCallId)
    return op->BuilderNode;

  // Clear cache for subroutine re-entry
  if(!TypeCheckOnly && CallOp && op->Cache && op->Cache->CallId != CurrentCallId)
  {
    op->Conversions.Clear();
    op->Extractions.Clear();
    op->Cache->CallId = 0;
    sRelease(op->Cache);
  }

  // Cycle detection
  if(op->CycleCheck != 0)
  {
    Error(op, L"cyclic connection");
    return 0;
  }
  op->CycleCheck++;

  // Map inputs: merge physical inputs, links, and defaults
  sArray<wOp *> &inputs = rd->inputs;
  inputs.Clear();

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

  // Handle special operator types
  if(op->Class->Flags & wCF_CALL)      // Subroutine call
  {
    // ... handle Call operator (see flow control section)
  }
  else if(op->Class->Flags & wCF_INPUT) // Subroutine input
  {
    // ... handle Input operator
  }
  else if(op->Class->Flags & wCF_LOOP)  // Loop expansion
  {
    // ... handle Loop operator
  }
  else
  {
    // Normal operator: create node and recursively parse inputs
    node = MakeNode(inputs.GetCount(), FakeInputs.GetCount());
    node->Op = op;
    node->CallId = CurrentCallId;
    node->OutType = op->Class->OutputType;
    op->BuilderNode = node;
    AllNodes.AddTail(node);

    for(sInt i = 0; i < inputs.GetCount(); i++)
    {
      if(inputs[i])
        node->Inputs[i] = ParseR(inputs[i], recursion + 1);
    }
  }

  op->CycleCheck--;
  return node;
}
```

**What happens**: ParseR recursively transforms the `wOp` graph into `wNode` intermediate representation. Key aspects:

- **Memoization per context**: `op->BuilderNode` caches the node for this op, but respects `CallId` for subroutine isolation
- **Cycle detection**: `op->CycleCheck` prevents infinite loops
- **Input resolution**: Merges physical connections, named links, and defaults
- **Flow control**: Special handling for Call, Input, Loop operators

---

### 4. Phase 2 - Cache Optimization: wBuilder::OptimizeCacheR
**File**: `altona/main/wz4lib/build.cpp:479`

```cpp
void wBuilder::OptimizeCacheR(wNode **node)
{
  if((*node)->Visited != 1)
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
        op->CacheLRU = Doc->CacheLRU++;  // Update LRU counter
        AllNodes.AddTail(*node);
      }
      else if(!((op->Class->Flags & wCF_PASSOUTPUT) &&
                (*node)->OutputCount == 1 && !op->ImportantOp))
      {
        // Mark for cache store (unless PASSOUTPUT and single consumer)
        if(!Doc->IsPlayer)
          (*node)->StoreCache = 1;
      }
    }
    (*node)->Visited = 1;

    // Recurse to children
    for(sInt i = 0; i < (*node)->FakeInputCount; i++)
    {
      if((*node)->Inputs[i])
        OptimizeCacheR(&((*node)->Inputs[i]));
    }
  }
}
```

**What happens**: This pass decides where to load from cache vs. execute, and where to store results:

- **Cache hit**: If `op->Cache` exists with matching `CallId`, replace the node with a cache load
- **Cache miss**: Mark the node for `StoreCache` after execution
- **PASSOUTPUT optimization**: Single-consumer nodes with PASSOUTPUT flag skip caching (the consumer will steal the reference)

---

### 5. Phase 5 - Command Generation: wBuilder::OutputR
**File**: `altona/main/wz4lib/build.cpp:695`

```cpp
wCommand *wBuilder::OutputR(wExecutive &exe, wNode *node)
{
  sVERIFY(node);
  sVERIFY(node->LoadCache == 0);

  sInt ic = node->InputCount;
  sInt fc = node->FakeInputCount;
  wCommand **objs = sALLOCSTACK(wCommand *, fc);

  node->CycleCheck++;

  // Generate commands for all inputs first
  for(sInt i = 0; i < fc; i++)
  {
    objs[i] = 0;
    if(node->Inputs[i])
    {
      if(node->Inputs[i]->LoadCache)
      {
        // Create inline cache load command
        wCommand *lc = exe.MemPool->Alloc<wCommand>();
        lc->Init();
        lc->Output = node->Inputs[i]->Op->Cache;
        lc->OutputVarCount = node->Inputs[i]->Op->CacheVars.GetCount();
        // ... copy cached script variables ...
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

  node->CycleCheck--;

  // Create command for this node
  wCommand *cmd = MakeCommand(exe, node->Op, objs, ic,
                               node->ScriptOp, 0, 0,
                               node->CallId, fc);
  cmd->LoopName = node->LoopName;
  cmd->LoopValue = node->LoopValue;
  cmd->LoopFlag = node->LoopFlag;

  if(node->StoreCache)
    cmd->StoreCacheOp = node->Op;

  return cmd;
}
```

**What happens**: Converts the `wNode` tree into a flat `wCommand` list via depth-first traversal:

- **Topological ordering**: Dependencies are added before dependents
- **Cache loads**: Inlined as lightweight commands that just return cached output
- **Command data**: Parameters, strings, and array data are copied from the operator

---

### 6. Command Creation: wBuilder::MakeCommand
**File**: `altona/main/wz4lib/build.cpp:618`

```cpp
wCommand *wBuilder::MakeCommand(wExecutive &exe, wOp *op,
                                 wCommand **inputs, sInt inputcount,
                                 wOp *scriptop, wOp *dummy,
                                 const sChar *dummy1, sInt callid,
                                 sInt fakeinputcount)
{
  wCommand *cmd = exe.MemPool->Alloc<wCommand>();
  cmd->Init();

  cmd->Op = op;
  cmd->Code = op ? op->Class->Command : 0;  // Function pointer to execute
  cmd->CallId = callid;

  // Handle PASSINPUT optimization
  if(op && (op->Class->Flags & wCF_PASSINPUT))
    cmd->PassInput = 0;

  // Setup scripting
  if(scriptop && scriptop->ScriptSourceValid)
  {
    sTextBuffer tb;
    scriptop->MakeSource(tb);
    cmd->ScriptSource = MakeString(tb.Get());
    cmd->Script = scriptop->GetScript();
    cmd->ScriptBind2 = scriptop->Class->Bind2Para;
  }

  // Copy parameter data
  if(op)
  {
    cmd->DataCount = op->Class->ParaWords;
    cmd->Data = exe.MemPool->Alloc<sU32>(cmd->DataCount);
    sCopyMem(cmd->Data, op->EditData, cmd->DataCount * sizeof(sU32));
  }

  // Copy string parameters
  if(op)
  {
    cmd->StringCount = op->Class->ParaStrings;
    cmd->Strings = exe.MemPool->Alloc<const sChar *>(cmd->StringCount);
    for(sInt i = 0; i < cmd->StringCount; i++)
    {
      sInt len = op->EditString[i]->GetCount();
      sChar *dest = exe.MemPool->Alloc<sChar>(len + 1);
      cmd->Strings[i] = dest;
      sCopyMem(dest, op->EditString[i]->Get(), sizeof(sChar) * (len + 1));
    }
  }

  // Copy array parameters (e.g., spline control points)
  if(op)
  {
    sInt words = op->Class->ArrayCount;
    sInt elems = op->ArrayData.GetCount();
    if(words > 0 && elems > 0)
    {
      sU32 *ptr = exe.MemPool->Alloc<sU32>(words * elems);
      cmd->ArrayCount = elems;
      cmd->Array = ptr;
      for(sInt i = 0; i < elems; i++)
      {
        sCopyMem(ptr, op->ArrayData[i], words * 4);
        ptr += words;
      }
    }
  }

  // Link input commands
  cmd->InputCount = inputcount;
  cmd->FakeInputCount = fakeinputcount;
  cmd->Inputs = exe.MemPool->Alloc<wCommand *>(cmd->FakeInputCount);
  for(sInt i = 0; i < cmd->FakeInputCount; i++)
    cmd->Inputs[i] = inputs[i];

  exe.Commands.AddTail(cmd);
  return cmd;
}
```

**What happens**: Creates a self-contained `wCommand` by copying all data needed for execution:

- **Function pointer**: `cmd->Code` points to the operator's execution function
- **Parameters**: Copied from EditData (the operator's parameter block)
- **Strings**: Deep copied so the command is independent of the editor state
- **Arrays**: Flattened and copied (used for splines, etc.)

---

### 7. Phase 6 - Execution: wExecutive::Execute
**File**: `altona/main/wz4lib/doc.cpp:3979`

```cpp
wObject *wExecutive::Execute(sBool progress, sBool depend)
{
  wCommand *cmd;
  sBool allok = 1;
  wObject *result = 0;
  sInt cmdcount = Commands.GetCount();
  sInt ProgressTimer = sGetTime() + 500;

  if(cmdcount > 0)
  {
    // Clear error state
    sFORALL(Commands, cmd)
      if(cmd->Op)
        cmd->Op->CalcErrorString = 0;

    // Execute each command in sequence
    sFORALL(Commands, cmd)
    {
      sBool ok = 1;

      if(allok)
      {
        // Handle weak cache reuse
        if(cmd->Op && cmd->Op->WeakCache)
        {
          cmd->Output = cmd->Op->WeakCache;
          cmd->Output->Reuse();
          cmd->Output->AddRef();
        }

        // Handle PASSINPUT optimization (steal input reference)
        if(cmd->PassInput >= 0)
        {
          wObject *in = cmd->GetInput<wObject *>(cmd->PassInput);
          if(in && in->RefCount == 1)
          {
            cmd->Output = in;
            cmd->Inputs[cmd->PassInput]->Output = 0;
          }
        }

        // Run script (if any)
        if(cmd->Script)
        {
          cmd->Script->PushGlobal();
          cmd->Script->ClearImports();
          // ... import variables from inputs ...
          // ... run script ...
          cmd->Script->Run();
        }

        // Execute the operator
        if(cmd->Code)
        {
          if(!(*cmd->Code)(this, cmd))  // Call operator function
            ok = 0;
          if(ok && cmd->Output)
            cmd->Output->CallId = cmd->CallId;
        }
        else
        {
          // No-op: pass through first input
          if(cmd->InputCount > 0 && cmd->Inputs[0] &&
             cmd->Inputs[0]->Output)
          {
            cmd->Output = cmd->Inputs[0]->Output;
            cmd->Output->AddRef();
          }
        }

        // Store in cache if marked
        if(cmd->StoreCacheOp && allok)
        {
          if(cmd->StoreCacheOp->Cache)
            cmd->StoreCacheOp->Cache->Release();
          cmd->StoreCacheOp->Cache = cmd->Output;
          cmd->StoreCacheOp->CacheLRU = Doc->CacheLRU++;
          // ... copy script variables to cache ...
          cmd->Output->AddRef();
        }
      }

      // Release inputs after use
      for(sInt i = 0; i < cmd->InputCount; i++)
        if(cmd->Inputs[i])
          cmd->Inputs[i]->Output->Release();

      // Keep final result, release intermediates
      if(_i == cmdcount - 1 && allok)
        result = cmd->Output;
      else
        cmd->Output->Release();
    }
  }

  return result;
}
```

**What happens**: Executes the command list in order:

1. **Script execution**: Runs operator scripts with imported variables
2. **Operator call**: `(*cmd->Code)(this, cmd)` invokes the operator's C++ function
3. **PASSINPUT**: Steals input reference when possible (avoids copy)
4. **Cache store**: Saves result for future reuse
5. **Reference management**: Releases inputs, keeps final result

---

## Data Flow Diagram

```
User Action: Select operator in editor
    |
    v
wDocument::CalcOp(op)                    Entry point
    |
    v
wBuilder::Execute(exe, op)               Compilation orchestrator
    |
    +---> Parse(op)                      Phase 1: Build node graph
    |         |
    |         v
    |     ParseR(op, 0)                  Recursive descent
    |         |
    |         +---> Handle wCF_CALL      Subroutine expansion
    |         +---> Handle wCF_LOOP      Loop unrolling
    |         +---> Handle wCF_INPUT     Parameter injection
    |         |
    |         v
    |     wNode* graph                   Intermediate representation
    |
    +---> Optimize(cache=1)              Phase 2: Cache optimization
    |         |
    |         +---> Remove nops          Skip passthrough operators
    |         +---> Insert conversions   Auto type conversion
    |         +---> OptimizeCacheR()     Load/Store cache points
    |         |
    |         v
    |     Optimized wNode graph
    |
    +---> TypeCheck()                    Phase 3: Validate types
    |
    +---> SkipToSlow()                   Phase 4: Handle slow ops
    |
    +---> Output(exe)                    Phase 5: Generate commands
    |         |
    |         v
    |     OutputR(exe, Root)             Depth-first traversal
    |         |
    |         +---> MakeCommand()        Copy params, link inputs
    |         |
    |         v
    |     wCommand[] sequence            Flat execution list
    |
    v
wExecutive::Execute()                    Phase 6: Run commands
    |
    +---> For each command:
    |         |
    |         +---> Run script (if any)
    |         +---> (*cmd->Code)(exe, cmd)  Invoke operator
    |         +---> Store cache (if marked)
    |         +---> Release inputs
    |
    v
wObject* result                          Final output object
    |
    v
wDocument::Show(result, pi)              Render to screen
    |
    v
wType::Show(obj, pi)                     Type-specific rendering
```

---

## Flow Control Operators

### Call (wCF_CALL) - Subroutine Invocation

```cpp
// From ParseR, handling wCF_CALL
if(op->Class->Flags & wCF_CALL)
{
  // Evaluate inputs to the call
  node = MakeNode(inputs.GetCount());
  for(sInt i = 1; i < inputs.GetCount(); i++)
    node->Inputs[i] = ParseR(inputs[i], recursion + 1);

  // Push current context
  wBuilderPush push;
  push.GetFrom(this);

  // Setup subroutine context
  CallInputs = node;          // Make inputs available to Input ops
  CallOp = op;
  CurrentCallId = CallId++;   // Unique ID for this call instance

  // Evaluate subroutine body (input[0] is the subroutine's output)
  LoopFlag = 1;
  node = MakeNode(1);
  node->Inputs[0] = ParseR(inputs[0], recursion + 1);
  node->OutType = node->Inputs[0]->OutType;

  // Restore context
  push.PutTo(this);
}
```

**Key insight**: Each Call gets a unique `CallId`, allowing the same operator to be evaluated differently in different call contexts. The cache respects this ID.

### Input (wCF_INPUT) - Parameter Injection

```cpp
// From ParseR, handling wCF_INPUT
if(op->Class->Flags & wCF_INPUT)
{
  sInt n = op->EditU()[0] + 1;  // Which input to inject

  if(CallInputs == 0)
    Error(op, L"input node not in subroutine call");
  else if(n >= CallInputs->InputCount)
    Error(CallOp, L"call has too few inputs");
  else
  {
    node = MakeNode(1, FakeInputs.GetCount());
    node->Inputs[0] = CallInputs->Inputs[n];  // Reference call's input
    node->OutType = node->Inputs[0]->OutType;

    // Also inject fake inputs for script variable propagation
    for(sInt i = 0; i < FakeInputs.GetCount(); i++)
      node->Inputs[1 + i] = FakeInputs[i];
  }
}
```

**Key insight**: Input operators inside a subroutine reference the actual inputs passed to the Call, enabling parameter substitution.

### Loop (wCF_LOOP) - Iteration

```cpp
// From ParseR, handling Loop inputs
if(inputs[i] && inputs[i]->Class->Flags & wCF_LOOP)
{
  wOp *mul = inputs[i];
  sInt max = inputs[i]->EditU()[0];  // Loop count

  // Expand loop iterations as separate inputs
  for(sInt j = 1; j < max; j++)
  {
    inputs.AddAfter(mul, i++);
    inputloop[i] = j;  // Track iteration index
  }
}

// Later, when parsing each iteration:
if(inputloop.Get(i) >= 0)
{
  CurrentCallId = op->BuilderNodeCallerId + inputloop.Get(i);

  // Create fake input for loop counter variable
  wNode *fake = MakeNode(0, 0);
  fake->LoopName = sPoolString(buffer);  // e.g., "i"
  fake->LoopValue = inputloop.Get(i);    // 0, 1, 2, ...
  FakeInputs.AddTail(fake);

  node->Inputs[i] = ParseR(inputs[i]->Inputs[0], recursion + 1);
}
```

**Key insight**: Loops are unrolled at compile time, with each iteration getting a unique CallId. Loop counters are injected as script variables.

---

## Key Data Structures

### wOp - Editor-Side Operator

```cpp
// From doc.hpp
class wOp : public sObject
{
  wDocName Name;                    // Operator name
  wClass *Class;                    // Operator type definition
  wPage *Page;                      // Containing page

  void *EditData;                   // Parameter values
  sTextBuffer **EditString;         // String parameters
  sArray<wOpInputInfo> Links;       // Named links
  sArray<wOp *> Inputs;             // Physical inputs
  sArray<void *> ArrayData;         // Array parameters (splines, etc.)

  wNode *BuilderNode;               // Temporary: node during compilation
  sInt BuilderNodeCallId;           // Which call context
  wObject *Cache;                   // Cached result
  sU32 CacheLRU;                    // For cache eviction

  sTextBuffer ScriptSource;         // Per-operator script code
  ScriptContext *Script;            // Compiled script
};
```

### wNode - Intermediate Representation

```cpp
// From build.hpp
struct wNode
{
  wOp *Op;                          // Source operator
  wOp *ScriptOp;                    // Script source (for subroutine injection)
  wNode **Inputs;                   // Input nodes
  wType *OutType;                   // Resolved output type
  sInt InputCount;                  // Real inputs
  sInt FakeInputCount;              // Including script variable carriers
  sInt CallId;                      // Subroutine context ID

  sPoolString LoopName;             // Loop counter variable name
  sF32 LoopValue;                   // Loop counter value
  sInt LoopFlag;                    // Inside loop/call context

  sInt OutputCount;                 // Consumer count (for cache decisions)
  sU8 StoreCache;                   // Mark: store result in cache
  sU8 LoadCache;                    // Mark: load from cache instead of execute
  wCommand *StoreCacheDone;         // Output command (for DAG deduplication)
};
```

### wCommand - Runtime Execution Unit

```cpp
// From doc.hpp
struct wCommand
{
  sBool (*Code)(wExecutive *, wCommand *);  // Operator function
  sInt DataCount;                   // Parameter word count
  sU32 *Data;                       // Parameter data
  sInt StringCount;                 // String parameter count
  const sChar **Strings;            // String data
  sInt InputCount;                  // Input command count
  wCommand **Inputs;                // Input commands
  sInt ArrayCount;                  // Array element count
  void *Array;                      // Array data

  wObject *Output;                  // Execution result
  sInt PassInput;                   // Steal input reference (-1 = off)
  sInt CallId;                      // Context for cache validation
  sInt LoopFlag;                    // Inside loop/call

  wOp *Op;                          // Back-reference (editor only)
  wOp *StoreCacheOp;                // Cache store target
  ScriptContext *Script;            // Compiled script
  const sChar *ScriptSource;        // Script source code
};
```

---

## Key Observations

### 1. Copy-on-Compile Architecture

The command generation phase (`MakeCommand`) copies all parameter data from the operator into the command. This:
- **Decouples execution from editing** - Commands are self-contained snapshots
- **Enables parallel execution** - No shared mutable state
- **Simplifies undo** - Original operator data unchanged during execution

### 2. Context-Aware Caching

The `CallId` system enables sophisticated caching:
- Same operator in different subroutine calls gets different cache entries
- Loop iterations are tracked separately
- Cache invalidation is precise: only the affected context is cleared

```cpp
// Cache lookup respects CallId
if(op->Cache && op->Cache->CallId == (*node)->CallId)
{
  // Cache hit - same context
  *node = MakeNode(0);
  (*node)->LoadCache = 1;
}
```

### 3. Reference Stealing (PASSINPUT)

When an operator's input has only one consumer, it can "steal" the reference:

```cpp
if(cmd->PassInput >= 0)
{
  wObject *in = cmd->GetInput<wObject *>(cmd->PassInput);
  if(in && in->RefCount == 1)  // Only consumer
  {
    cmd->Output = in;          // Steal reference
    cmd->Inputs[cmd->PassInput]->Output = 0;  // Clear source
  }
}
```

This avoids unnecessary copies for in-place operations like `Add`, `Multiply`, etc.

### 4. Script Variable Propagation

Variables flow through the graph via "fake inputs" - extra input slots that carry script context:

```cpp
// Loop counter becomes a script variable
fake->LoopName = L"i";
fake->LoopValue = iteration;
FakeInputs.AddTail(fake);

// During execution, variables are imported from all inputs
for(sInt j = 0; j < cmd->Inputs[i]->OutputVarCount; j++)
{
  wScriptVar *var = cmd->Inputs[i]->OutputVars + j;
  cmd->Script->AddImport(var->Name, var->Type, var->Count, var->IntVal);
}
```

### 5. LRU Cache Eviction

The document tracks `CacheLRU` to enable memory management:

```cpp
op->CacheLRU = Doc->CacheLRU++;  // Timestamp on access

// Later, eviction can use this:
sBool wDocument::UnCacheLRU()
{
  // Find oldest cached result, release it
}
```

---

## Implications for Rust Framework

### Adopt

1. **Two-tier compilation model** - Separate graph representation (editor) from execution sequence (runtime)
2. **Context-aware caching with IDs** - Essential for subroutines and loops
3. **Reference stealing optimization** - Use `Arc::try_unwrap()` or move semantics
4. **Flat command buffer** - Better cache locality than recursive execution

### Modify

1. **Memory pool allocation** - Replace with Rust arena allocators (`bumpalo`, `typed-arena`)
2. **Error handling** - Use `Result<T, E>` instead of error flag + pointer
3. **Script integration** - Consider `rhai` or `mlua` with safer type bindings
4. **Type system** - Leverage Rust enums for operator types instead of runtime flags

### Avoid

1. **Extensive use of raw pointers** - Use smart pointers, indices, or arenas
2. **Global document pointer** - Pass context explicitly or use dependency injection
3. **Manual reference counting** - Use `Arc<T>` for shared ownership
4. **Implicit state mutation** - Make Builder state explicitly scoped

### API Sketch

```rust
// Node graph compilation
pub struct GraphCompiler<'a> {
    pool: &'a bumpalo::Bump,
    nodes: Vec<Node<'a>>,
    call_id: u32,
    current_context: CallContext,
}

impl<'a> GraphCompiler<'a> {
    pub fn compile(&mut self, root: &Operator) -> Result<CommandBuffer<'a>, CompileError> {
        let node = self.parse(root, 0)?;
        self.optimize(&mut node)?;
        self.type_check(&node)?;
        self.output(node)
    }

    fn parse(&mut self, op: &Operator, depth: usize) -> Result<Node<'a>, CompileError> {
        // Check for cached node in current context
        if let Some(cached) = op.builder_node(self.current_context) {
            return Ok(cached);
        }

        // Cycle detection via depth limit + visited set
        if depth > MAX_DEPTH {
            return Err(CompileError::CycleDetected);
        }

        match op.class().flags {
            OpFlags::CALL => self.parse_call(op, depth),
            OpFlags::LOOP => self.parse_loop(op, depth),
            OpFlags::INPUT => self.parse_input(op),
            _ => self.parse_normal(op, depth),
        }
    }
}

// Command buffer execution
pub struct CommandBuffer<'a> {
    commands: Vec<Command<'a>>,
    pool: &'a bumpalo::Bump,
}

impl<'a> CommandBuffer<'a> {
    pub fn execute(&self) -> Result<Arc<dyn Object>, ExecError> {
        let mut results: Vec<Option<Arc<dyn Object>>> = vec![None; self.commands.len()];

        for (i, cmd) in self.commands.iter().enumerate() {
            // Gather inputs (steal if possible)
            let inputs: Vec<_> = cmd.input_indices.iter()
                .map(|&idx| results[idx].take().unwrap())
                .collect();

            // Execute operator
            let output = (cmd.code)(cmd, &inputs)?;

            // Store result (handle caching)
            if let Some(cache_slot) = cmd.cache_slot {
                cache_slot.store(output.clone());
            }
            results[i] = Some(output);
        }

        results.pop().flatten().ok_or(ExecError::NoOutput)
    }
}

// Context for subroutine/loop isolation
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CallContext(u32);

// Cache with context awareness
pub struct ContextCache {
    entries: HashMap<(OperatorId, CallContext), CacheEntry>,
    lru: LruTracker,
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
| `altona/main/wz4lib/basic_ops.ops` | Store, Load, Call, Loop operator definitions |
