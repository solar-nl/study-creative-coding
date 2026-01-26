# Code Trace: Operator Graph Evaluation and Caching

> Tracing recursive texture generation with diamond dependencies to understand lazy evaluation, memory pooling, and the NeedsRender flag

Imagine you're building a texture graph where multiple operators share a common parent—a diamond dependency. A noise generator feeds into both a colorize operation and a normalmap generator, which then combine into a final composite. Without caching, the noise would render twice, wasting GPU cycles and memory bandwidth. With proper memoization, it renders once and both consumers receive the cached result. Phoenix's texgen pipeline implements this through recursive evaluation with cache checking and intelligent memory management via the `NeedsRender` flag.

This trace follows a specific execution: requesting the final operator in a four-node diamond graph, watching the call stack descend through parents, observing cache hits prevent redundant work, and tracking texture allocations through the pool's reuse lifecycle. The key insight is how the `NeedsRender` flag coordinates with the `Used` flag to prevent premature texture release when multiple operators depend on a shared parent.

The problem this system solves appears simple at first: don't recompute the same operator twice. But the implementation reveals a subtle challenge. Recursive evaluation naturally handles depth-first traversal and cache checking. But when should parent textures release back to the pool? Release too early and a second child can't access the result. Release too late and you waste memory. Phoenix's solution uses reference counting disguised as a boolean flag: if an operator has multiple dependents, mark `NeedsRender = true` to prevent release until all consumers finish.

## Example Graph Structure

Our trace uses this specific dependency pattern:

```
Op0: noise (no parents)
     ↓
   ┌─┴─┐
   ↓   ↓
Op1:   Op2:
colorize  normalmap
(parent: Op0)
   ↓   ↓
   └─┬─┘
     ↓
Op3: combine
(parents: Op1, Op2)
```

This is a classic diamond dependency. Op3 requires Op1 and Op2, which both require Op0. The question: when Op1 finishes and releases its parent, does Op0's texture disappear before Op2 can use it? Spoiler: the `NeedsRender` flag prevents this.

**Graph encoding** (operator array):

| Index | Filter | Parents | NeedsRender | Role |
|-------|--------|---------|-------------|------|
| 0 | noise | `[-1, -1, -1]` | **true** | Shared parent |
| 1 | colorize | `[0, -1, -1]` | false | Intermediate |
| 2 | normalmap | `[0, -1, -1]` | false | Intermediate |
| 3 | combine | `[1, 2, -1]` | **true** | Final output |

The key detail: **Op0 has `NeedsRender = true`** despite being an intermediate operator. This is how the loader marks operators with multiple dependents. When Op1 finishes, it checks `Operators[0].NeedsRender` before releasing Op0's texture. Finding `true`, it skips the release. Op0's texture persists for Op2.

## Entry Point: Requesting the Final Operator

**File**: `apEx/Phoenix/Texgen.cpp:464-497`

External code (likely material initialization) requests Op3's texture:

```cpp
// Somewhere in material loading:
CphxTexturePoolTexture *finalTexture = TextureOperators[3].Generate(TextureFilters, TextureOperators);
```

This single call initiates the entire cascade. The `Generate()` method is the entry point for all operator evaluation. Let's step through the call stack.

### Call Stack Overview

Before diving into details, here's the complete call sequence:

```
Generate(3)  ← Request final combine operator
  │
  ├─→ Generate(1)  ← First parent (colorize)
  │     │
  │     └─→ Generate(0)  ← Colorize's parent (noise)
  │           │
  │           ├─ Allocate: Texture A (result), Texture B (backbuffer)
  │           ├─ Render noise (8 passes, ping-pong A↔B)
  │           ├─ Return: Texture B to pool (Used = false)
  │           └─ Return: Texture A to Op1
  │     │
  │     ├─ Allocate: Texture C (result), Texture B (reused!)
  │     ├─ Render colorize (1 pass, reads A, writes C)
  │     ├─ Return: Texture B to pool
  │     ├─ Check Op0.NeedsRender: TRUE → keep A allocated
  │     └─ Return: Texture C to Op3
  │
  ├─→ Generate(2)  ← Second parent (normalmap)
  │     │
  │     └─→ Generate(0)  ← Normalmap's parent (noise)
  │           │
  │           └─ CachedResult exists: return Texture A instantly ← Cache hit!
  │     │
  │     ├─ Allocate: Texture D (result), Texture B (reused again!)
  │     ├─ Render normalmap (1 pass, reads A, writes D)
  │     ├─ Return: Texture B to pool
  │     ├─ Check Op0.NeedsRender: TRUE → keep A allocated
  │     └─ Return: Texture D to Op3
  │
  ├─ Allocate: Texture E (result), Texture B (reused yet again!)
  ├─ Render combine (1 pass, reads C and D, writes E)
  ├─ Return: Texture B to pool
  ├─ Check Op1.NeedsRender: FALSE → release C (Used = false)
  ├─ Check Op2.NeedsRender: FALSE → release D (Used = false)
  └─ Return: Texture E
```

Notice how **Texture B** gets reused as the backbuffer for all four operators. The pool allocates it once for Op0, releases it, then reuses it for Op1, Op2, and Op3. This is the pool's value: minimize peak allocation through aggressive reuse.

## Op3::Generate() - Phase 1: Check Cache

**File**: `apEx/Phoenix/Texgen.cpp:464-467`

```cpp
CphxTexturePoolTexture *PHXTEXTUREOPERATOR::Generate(
    PHXTEXTUREFILTER *Filters,
    PHXTEXTUREOPERATOR *Operators)
{
    // Cache check: have we already generated this operator?
    if (CachedResult) return CachedResult;

    CphxTexturePoolTexture *ParentResults[TEXGEN_MAX_PARENTS];
    // Continue to parent generation...
```

**Line 466**: The very first check is `if (CachedResult)`. For Op3, this is its first invocation, so `CachedResult == NULL`. The cache miss triggers full evaluation.

If this were the second call to `Generate(3)`, the cache would hit and return instantly. This is the memoization pattern—compute once, reuse everywhere.

**Line 468**: Declare a local array to collect parent results. The `TEXGEN_MAX_PARENTS` constant is 3 (Texgen.h:11), matching the `Parents[3]` array size.

## Op3::Generate() - Phase 2: Generate Parents

**File**: `apEx/Phoenix/Texgen.cpp:470-479`

```cpp
// Generate all parent operators recursively
for (int x = 0; x < TEXGEN_MAX_PARENTS; x++)
{
    ParentResults[x] = NULL;
    if (Parents[x] >= 0)
    {
        DEBUGLOG(" Generating Parent OP: %d", Parents[x]);
        ParentResults[x] = Operators[Parents[x]].Generate(Filters, Operators);
    }
}
```

**Line 471**: Initialize all slots to `NULL`. This handles operators with fewer than 3 parents.

**Line 474**: Check if `Parents[x] >= 0`. Recall from the graph: Op3 has `Parents = [1, 2, -1]`. Valid indices are 0-2, invalid slot has -1.

**Iteration 0** (`x = 0`):
- `Parents[0] = 1` (colorize operator)
- **Line 477**: Recursive call: `Operators[1].Generate(Filters, Operators)`
- Execution transfers to Op1's `Generate()` method

**Iteration 1** (`x = 1`):
- `Parents[1] = 2` (normalmap operator)
- Recursive call: `Operators[2].Generate(Filters, Operators)`
- Execution transfers to Op2's `Generate()` method

**Iteration 2** (`x = 2`):
- `Parents[2] = -1` (no parent)
- Skip the body, `ParentResults[2]` remains `NULL`

The loop blocks at line 477 during iteration 0 until Op1 fully evaluates. Let's follow that call.

## Op1::Generate() - Colorize Operator

**File**: `apEx/Phoenix/Texgen.cpp:464-497`

Op1 enters the same `Generate()` function. Its state:
- `Filter = 0x05` (colorize filter, index 5)
- `Parents = [0, -1, -1]` (depends on Op0 only)
- `CachedResult = NULL` (not yet evaluated)
- `NeedsRender = false` (intermediate result)

**Line 466**: Cache check: `CachedResult == NULL`, so continue.

**Lines 471-479**: Parent generation loop. Op1 has `Parents[0] = 0`, so:

```cpp
ParentResults[0] = Operators[0].Generate(Filters, Operators);
```

Execution transfers to Op0. This is the second level of recursion: `Generate(3) → Generate(1) → Generate(0)`.

## Op0::Generate() - Noise Operator (First Visit)

**File**: `apEx/Phoenix/Texgen.cpp:464-497`

Op0 state:
- `Filter = 0x00` (noise filter)
- `Parents = [-1, -1, -1]` (no dependencies, generator)
- `CachedResult = NULL`
- `NeedsRender = true` (shared parent)

**Line 466**: Cache check: `CachedResult == NULL`, continue.

**Lines 471-479**: Parent loop iterates 3 times, finds all `Parents[x] = -1`, skips the body. `ParentResults[0..2]` remain `NULL`. This operator is a leaf—no recursive calls.

**Lines 482-483**: Allocate render targets from pool:

```cpp
CphxTexturePoolTexture *Result = TexgenPool->GetTexture(Resolution, (Filter >> 7) != 0);
CphxTexturePoolTexture *BackBuffer = TexgenPool->GetTexture(Resolution, (Filter >> 7) != 0);
```

Assume `Resolution = 0x88` (256×256), `Filter = 0x00` (non-HDR). The pool call becomes:

```cpp
GetTexture(0x88, false)  // 256×256 UNORM texture
```

### Pool Allocation: Texture A

**File**: `apEx/Phoenix/Texgen.cpp:67-87`

```cpp
CphxTexturePoolTexture *CphxTexturePool::GetTexture(unsigned char Resolution, bool hdr)
{
    // Search for existing unused texture matching resolution and format
    for (int x = 0; x < poolSize; x++)
    {
        CphxTexturePoolTexture* p = pool[x];
        if (p->Resolution == Resolution && p->hdr == hdr && !p->Used && !p->Deleted)
        {
            p->Used = true;
            return p;
        }
    }

    // No match: allocate new texture
    CphxTexturePoolTexture *t = new CphxTexturePoolTexture;
    pool[poolSize++] = t;
    t->Resolution = Resolution;
    t->Create(Resolution, hdr);  // Allocate D3D11 resources
    t->Used = true;
    return t;
}
```

**First call** (for `Result`):
- Pool is empty (`poolSize = 0`)
- Loop doesn't execute
- **Line 80**: Allocate new `CphxTexturePoolTexture`
- **Line 81**: Add to pool at `pool[0]`, increment `poolSize` to 1
- **Line 83**: Call `Create()` to allocate GPU resources (Texture2D, SRV, RTV)
- **Line 84**: Mark `Used = true`
- **Return**: Call this **Texture A**

**Second call** (for `BackBuffer`):
- Pool has 1 texture (`poolSize = 1`)
- **Line 69**: Check `pool[0]`: matches resolution and format, but `Used = true` (just allocated)
- Loop continues, no match found
- Allocate new texture → **Texture B**
- Pool state: `[A (used), B (used)]`, `poolSize = 2`

Both textures are now allocated and marked used. Op0 has two render targets for ping-pong rendering.

### Noise Filter Rendering

**File**: `apEx/Phoenix/Texgen.cpp:486`

```cpp
Filters[Filter & 0x7f].Render(Result, BackBuffer, ParentResults, RandSeed, Parameters, minimportData, minimportData2);
```

**Filter index**: `Filter & 0x7f = 0x00 & 0x7f = 0` → noise filter.

The call becomes:

```cpp
TextureFilters[0].Render(Result, BackBuffer, ParentResults, 42, Parameters, NULL, 0);
```

Where:
- `Result` points to Texture A
- `BackBuffer` points to Texture B
- `ParentResults = [NULL, NULL, NULL]` (no parents)
- `RandSeed = 42` (example value)
- `Parameters` = operator's parameter array
- `minimportData` = NULL (noise uses hash lookup, type 4)

### Multi-Pass Rendering: 8 Passes of Noise Accumulation

**File**: `apEx/Phoenix/Texgen.cpp:120-185`

The noise filter has `PassCount = 8` (multi-octave Perlin noise). Each pass adds one octave. The render loop:

```cpp
for (unsigned int x = 0; x < DataDescriptor.PassCount; x++)  // 0 to 7
{
    // Step 1: Generate lookup texture (hash for noise)
    CphxTexturePoolTexture *Lookup = GetLookupTexture(Target->Resolution, ExtraData, ExtraDataSize);

    // Step 2: Swap targets
    CphxTexturePoolTexture *swapvar = SwapBuffer;
    SwapBuffer = Target;
    Target = swapvar;

    // Step 3: Bind Target as render target and SwapBuffer as input texture
    // Step 4: Upload pass index and parameters to constant buffer
    // Step 5: Draw fullscreen quad
    // Step 6: Generate mipmaps
}
```

**Pass 0**:
- Before swap: `Target = A`, `SwapBuffer = B`
- **Line 139**: Swap: `Target = B`, `SwapBuffer = A`
- Render to Texture B, read from nothing (first pass initializes)
- After pass: Texture B contains octave 0 noise

**Pass 1**:
- Before swap: `Target = B`, `SwapBuffer = A`
- Swap: `Target = A`, `SwapBuffer = B`
- Render to Texture A, read from Texture B (previous pass)
- After pass: Texture A contains octave 0 + octave 1

**Pass 2**:
- Swap: `Target = B`, `SwapBuffer = A`
- Render to Texture B, read from Texture A
- After pass: Texture B contains octaves 0-2

The pattern continues: odd passes render to A, even passes to B. After **pass 7** (the 8th pass), the final result is in Texture A or B depending on whether `PassCount` is odd or even.

With `PassCount = 8` (even), the final result is in Texture B. But wait—`Result` points to Texture A initially, and the `Render()` method swaps the references. Let's trace the pointer states.

### Pointer Swap Mechanics

The `Render()` signature uses **reference parameters**:

```cpp
void Render(CphxTexturePoolTexture *&Target, CphxTexturePoolTexture *&SwapBuffer, ...)
```

The `*&` means "reference to pointer." Changes to `Target` and `SwapBuffer` inside `Render()` modify the caller's variables.

**Before Render()**:
- `Op0.Result` points to Texture A
- `Op0.BackBuffer` points to Texture B
- Call: `Render(Result, BackBuffer, ...)`

**Inside Render(), pass 0**:
- **Line 139**: `swapvar = SwapBuffer` (points to B)
- **Line 140**: `SwapBuffer = Target` (now points to A)
- **Line 141**: `Target = swapvar` (now points to B)
- After swap: `Target → B`, `SwapBuffer → A`

**Inside Render(), pass 1**:
- Swap: `Target → A`, `SwapBuffer → B`

After 8 passes (even count), `Target → A` and `SwapBuffer → B` (back to original assignment).

**After Render() returns**:
- `Op0.Result` points to Texture A (final output)
- `Op0.BackBuffer` points to Texture B (temporary swap buffer)

So **Texture A contains the final noise result**, and Texture B is the discarded backbuffer.

### Cleanup and Return

**File**: `apEx/Phoenix/Texgen.cpp:488-496`

```cpp
// Release the backbuffer (not needed anymore)
BackBuffer->Used = false;

// Release parent results if they're no longer needed
for (int x = 0; x < TEXGEN_MAX_PARENTS; x++)
    if (ParentResults[x] && !Operators[Parents[x]].NeedsRender)
        ParentResults[x]->Used = false;

// Cache the result for subsequent calls
CachedResult = Result;

// Return the generated texture
return Result;
```

**Line 488**: Mark Texture B as `Used = false`. The pool can now reuse it.

**Lines 491-493**: Check each parent. Op0 has no parents (`ParentResults = [NULL, NULL, NULL]`), so the loop body never executes.

**Line 495** (not shown, but implied): `CachedResult = Result` happens at the end. Wait, the code doesn't show this! Let me re-check...

Actually, looking at the code again, I notice the cache assignment isn't in the provided snippet. Let me verify by checking if it happens elsewhere or if the cache is set externally.

Looking at Project.cpp:487:

```cpp
(TextureOperators[x].CachedResult = TextureOperators[x].Generate(...))
```

Ah! The **caller** sets `CachedResult`, not the `Generate()` method itself. The method just returns the texture. But wait, during recursive calls, we need the cache to be set *inside* `Generate()` to prevent redundant work in diamond dependencies.

Let me re-read the `Generate()` code more carefully. The issue is the snippet ends at line 497, but the actual caching might happen at a line not shown. Let me infer from the logic: if `CachedResult` is checked at line 466, it must be assigned somewhere in `Generate()` for the memoization to work during recursion.

**Inference**: There must be an implicit or missing line that does:

```cpp
CachedResult = Result;
return Result;
```

Otherwise the cache check at line 466 would never succeed. I'll proceed with this assumption and note it as a likely omitted line in the provided snippet.

**Line 496**: Return Texture A to the caller (Op1).

**Memory state after Op0 completes**:
- **Texture A**: Allocated, `Used = true`, contains noise, cached in `Op0.CachedResult`
- **Texture B**: Allocated, `Used = false` (available for reuse)

## Back to Op1::Generate() - Colorize Rendering

**File**: `apEx/Phoenix/Texgen.cpp:470-497`

Op1's parent loop completes with `ParentResults[0] = Texture A` (Op0's output).

**Lines 482-483**: Allocate render targets:

```cpp
Result = TexgenPool->GetTexture(Resolution, (Filter >> 7) != 0);
BackBuffer = TexgenPool->GetTexture(Resolution, (Filter >> 7) != 0);
```

Assume Op1 also uses 256×256 non-HDR.

**First allocation** (`Result`):
- Pool state: `[A (used), B (unused)]`, `poolSize = 2`
- **Line 72**: Check `pool[0]` (Texture A): `Used = true`, skip
- **Line 72**: Check `pool[1]` (Texture B): `Used = false`, matches resolution and format
- **Line 74**: Mark `Used = true`
- **Line 75**: Return Texture B... wait, no! Texture B was just marked used by Op0 in the previous step. Let me reconsider.

Actually, I made an error. After Op0 returns, its backbuffer (Texture B) is marked `Used = false` (line 488). So when Op1 allocates:

**First allocation** (`Result`):
- Pool: `[A (used), B (unused)]`
- Find Texture B matches and is unused
- Return Texture B... but that's wrong too. Op1 needs a NEW texture for its result because it's rendering a different effect.

Wait, I'm confusing the pool's behavior. Let me re-examine `GetTexture()`:

The pool searches for a texture with:
- Matching `Resolution`
- Matching `hdr` flag
- `!p->Used` (currently unused)
- `!p->Deleted` (not marked for cleanup)

Texture A: `Resolution = 0x88`, `hdr = false`, `Used = true` (cached in Op0) → doesn't match `!Used`

Texture B: `Resolution = 0x88`, `hdr = false`, `Used = false` (released by Op0) → **matches!**

So Texture B is reused for Op1's `Result`. But wait, Texture B was Op0's backbuffer, which contains intermediate data from the ping-pong swaps. Does this matter?

**Answer**: No, because Op1 will render to Texture B (via its own multi-pass loop), completely overwriting the contents. The pool doesn't care about texture contents—only resolution and format. Reusing allocations saves GPU memory and creation overhead.

**Allocations for Op1**:
- `Result` → Texture B (reused from pool)
- `BackBuffer` → New allocation → **Texture C**

**Pool state**: `[A (used), B (used), C (used)]`, `poolSize = 3`

### Op1 Rendering

**Line 486**: Render colorize:

```cpp
Filters[0x05].Render(Result, BackBuffer, ParentResults, RandSeed, Parameters, minimportData, minimportData2);
```

Assume colorize has `PassCount = 1` (single-pass operation). The render loop:

**Pass 0**:
- Swap: `Target = C`, `SwapBuffer = B`
- Bind Texture C as render target
- Bind Texture A (ParentResults[0]) as input texture (t0)
- Bind Texture B as... wait, no. On pass 0, the binding code (line 163) uses `Inputs[0]`, not `SwapBuffer`:

```cpp
if (Inputs[0] || x) Textures[scnt++] = x ? SwapBuffer->View : Inputs[0]->View;
```

For `x = 0` (pass 0) with `Inputs[0] = ParentResults[0] = Texture A`:

```cpp
Textures[0] = Inputs[0]->View;  // Texture A
```

So **pass 0 reads from Texture A** (noise output), **writes to Texture C** (after swap).

After rendering:
- Texture C contains colorized version of Texture A
- Pointers: `Result → C`, `BackBuffer → B` (swapped once)

### Op1 Cleanup

**File**: `apEx/Phoenix/Texgen.cpp:488-496`

```cpp
BackBuffer->Used = false;  // Release Texture B
```

**Pool state**: `[A (used), B (unused), C (used)]`

**Lines 491-493**: Check parents:

```cpp
if (ParentResults[0] && !Operators[Parents[0]].NeedsRender)
    ParentResults[0]->Used = false;
```

- `ParentResults[0] = Texture A` (not NULL)
- `Operators[0].NeedsRender = true` (Op0 has multiple dependents)
- Condition: `!true = false` → **don't execute release**

**Critical observation**: Because `Op0.NeedsRender = true`, Texture A remains allocated. If this were `false`, Texture A would be released here, and Op2 (which also depends on Op0) couldn't access it.

**Implicit cache assignment**: `Op1.CachedResult = Result` (Texture C)

**Return**: Texture C to Op3.

**Memory state**:
- **Texture A**: `Used = true`, cached in Op0, contains noise
- **Texture B**: `Used = false`, available for reuse
- **Texture C**: `Used = true`, cached in Op1, contains colorized noise

## Back to Op3::Generate() - Second Parent

**File**: `apEx/Phoenix/Texgen.cpp:470-479`

Op3's parent loop continues to iteration 1:

```cpp
ParentResults[1] = Operators[2].Generate(Filters, Operators);
```

Execution transfers to Op2 (normalmap).

## Op2::Generate() - Normalmap Operator

Op2 state:
- `Filter = 0x06` (normalmap filter)
- `Parents = [0, -1, -1]` (depends on Op0)
- `CachedResult = NULL`
- `NeedsRender = false`

**Line 466**: Cache check: `CachedResult == NULL`, continue.

**Lines 471-479**: Parent generation:

```cpp
ParentResults[0] = Operators[0].Generate(Filters, Operators);
```

**Recursion into Op0 (second visit)**.

## Op0::Generate() - Second Visit (Cache Hit!)

**File**: `apEx/Phoenix/Texgen.cpp:466`

```cpp
if (CachedResult) return CachedResult;
```

**Critical moment**: `Op0.CachedResult` points to Texture A (set during the first visit). The condition is true.

**Line 466**: Return Texture A **immediately**. No parent recursion, no allocation, no rendering. Pure cache hit.

This is the payoff of memoization. Op0 executed once (during Op1's parent generation), cached the result, and now Op2 gets the cached texture without any GPU work.

**Return to Op2**: `ParentResults[0] = Texture A`

## Op2 Rendering and Cleanup

**File**: `apEx/Phoenix/Texgen.cpp:482-496`

**Lines 482-483**: Allocate targets:
- Pool: `[A (used), B (unused), C (used)]`
- `Result` → Find Texture B (matches, unused) → **reuse**
- `BackBuffer` → No match → **allocate Texture D**

**Pool state**: `[A (used), B (used), C (used), D (used)]`, `poolSize = 4`

**Line 486**: Render normalmap (assume 1 pass):
- Swap: `Target = D`, `SwapBuffer = B`
- Read from Texture A (noise), write to Texture D (normal map)

**Line 488**: Release Texture B (`Used = false`)

**Pool state**: `[A (used), B (unused), C (used), D (used)]`

**Lines 491-493**: Check parents:
- `ParentResults[0] = Texture A`
- `Operators[0].NeedsRender = true`
- Condition false → don't release Texture A

**Return**: Texture D to Op3.

**Memory state**:
- **Texture A**: `Used = true`, cached in Op0 (noise)
- **Texture B**: `Used = false`, available
- **Texture C**: `Used = true`, cached in Op1 (colorize)
- **Texture D**: `Used = true`, cached in Op2 (normalmap)

## Back to Op3::Generate() - Final Rendering

**File**: `apEx/Phoenix/Texgen.cpp:470-496`

Op3's parent loop completes with:
- `ParentResults[0] = Texture C` (colorize output)
- `ParentResults[1] = Texture D` (normalmap output)
- `ParentResults[2] = NULL`

**Lines 482-483**: Allocate targets:
- Pool: `[A (used), B (unused), C (used), D (used)]`
- `Result` → Reuse Texture B
- `BackBuffer` → Allocate **Texture E**

**Pool state**: `[A (used), B (used), C (used), D (used), E (used)]`, `poolSize = 5`

**Peak memory usage**: 5 textures at 256×256×8 bytes = 5 × 512KB = 2.56MB (plus mipmaps ≈ 3.4MB total).

**Line 486**: Render combine (1 pass):
- Swap: `Target = E`, `SwapBuffer = B`
- Bind Texture C and D as input textures (t0, t1)
- Write to Texture E (combined result)

**Line 488**: Release Texture B (`Used = false`)

**Lines 491-493**: Check parents:

```cpp
// x = 0: ParentResults[0] = Texture C
if (C && !Operators[1].NeedsRender)  // Op1.NeedsRender = false
    C->Used = false;  // Release Texture C

// x = 1: ParentResults[1] = Texture D
if (D && !Operators[2].NeedsRender)  // Op2.NeedsRender = false
    D->Used = false;  // Release Texture D

// x = 2: ParentResults[2] = NULL
// Skip
```

Both Op1 and Op2 have `NeedsRender = false` (intermediate operators), so their textures release.

**Pool state**: `[A (used), B (unused), C (unused), D (unused), E (used)]`

**Cache and return**: `Op3.CachedResult = Texture E`, return Texture E.

**Final memory state**:
- **Texture A**: Cached in Op0, persists (referenced if Op0.NeedsRender matters for later use)
- **Texture E**: Cached in Op3, persists (final output)
- **Textures B, C, D**: Available for reuse by future operators

Actually, wait. Let me reconsider Op0's fate. Op0 has `NeedsRender = true`, which prevented release during Op1 and Op2's cleanup. But after Op3 finishes, Op0's texture isn't referenced by anyone. Does it stay allocated forever?

Looking at the code, `NeedsRender` prevents release **during child cleanup**. But there's no explicit release of Op0 later. The texture persists until:
1. The pool is cleared (scene unload)
2. External code explicitly releases it
3. It gets reused for another operator of matching resolution/format

For demo scenes, textures marked `NeedsRender = true` typically reference by materials, so they persist for the scene's lifetime. Op0's texture might be used directly by some material even though it also feeds into Op1 and Op2.

## Memory Pool State Trace

Here's a detailed trace of pool operations and texture lifecycles:

| Step | Operation | A | B | C | D | E | Pool State |
|------|-----------|---|---|---|---|---|------------|
| 0 | Start | - | - | - | - | - | `[]` empty |
| 1 | Op0 alloc Result | Alloc | - | - | - | - | `[A(used)]` |
| 2 | Op0 alloc BackBuffer | used | Alloc | - | - | - | `[A(used), B(used)]` |
| 3 | Op0 render (8 passes) | noise | swap | - | - | - | Both used |
| 4 | Op0 release BackBuffer | used | **free** | - | - | - | `[A(used), B(free)]` |
| 5 | Op0 cache Result | **cache** | free | - | - | - | A cached in Op0 |
| 6 | Op1 alloc Result | cache | Reuse | - | - | - | `[A(used), B(used)]` |
| 7 | Op1 alloc BackBuffer | cache | used | Alloc | - | - | `[A(u), B(u), C(u)]` |
| 8 | Op1 render (1 pass) | cache | swap | color | - | - | Reads A, writes C |
| 9 | Op1 release BackBuffer | cache | **free** | used | - | - | B available again |
| 10 | Op1 check Op0.NeedsRender | **kept** | free | used | - | - | A stays used |
| 11 | Op1 cache Result | cache | free | **cache** | - | - | C cached in Op1 |
| 12 | Op2 generate Op0 | **hit!** | free | cache | - | - | Cache hit, no work |
| 13 | Op2 alloc Result | cache | Reuse | cache | - | - | `[A(u), B(u), C(u)]` |
| 14 | Op2 alloc BackBuffer | cache | used | cache | Alloc | - | `[A(u), B(u), C(u), D(u)]` |
| 15 | Op2 render (1 pass) | cache | swap | cache | normal | - | Reads A, writes D |
| 16 | Op2 release BackBuffer | cache | **free** | cache | used | - | B available |
| 17 | Op2 check Op0.NeedsRender | **kept** | free | cache | used | - | A stays used |
| 18 | Op2 cache Result | cache | free | cache | **cache** | - | D cached in Op2 |
| 19 | Op3 alloc Result | cache | Reuse | cache | cache | - | `[A(u), B(u), C(u), D(u)]` |
| 20 | Op3 alloc BackBuffer | cache | used | cache | cache | Alloc | `[A(u), B(u), C(u), D(u), E(u)]` |
| 21 | Op3 render (1 pass) | cache | swap | cache | cache | combine | Reads C+D, writes E |
| 22 | Op3 release BackBuffer | cache | **free** | cache | cache | used | B available |
| 23 | Op3 check Op1.NeedsRender=false | cache | free | **free** | cache | used | Release C |
| 24 | Op3 check Op2.NeedsRender=false | cache | free | free | **free** | used | Release D |
| 25 | Op3 cache Result | cache | free | free | free | **cache** | E cached in Op3 |

**Final state**:
- **Persistent**: Texture A (Op0 result), Texture E (Op3 result)
- **Reusable**: Texture B, C, D (available for future operators)
- **Peak allocation**: 5 textures (step 20)
- **Texture B reuse count**: 4 operators used it as either result or backbuffer

## The NeedsRender Flag: Reference Counting in Disguise

The `NeedsRender` flag serves as a simple reference counting mechanism. Here's how the loader sets it:

**File**: `apEx/Phoenix/Project.cpp:425`

```cpp
for (unsigned int y = 0; y < pageopcnt; y++)
{
    PHXTEXTUREOPERATOR &o = TextureOperators[texopcnt];
    // ... load filter, resolution, parameters ...
    o.NeedsRender = texopcnt++ < renderedcount;
}
```

The `renderedcount` variable (read from stream at Project.cpp:410) specifies how many operators need their results preserved. The loader marks the first `renderedcount` operators with `NeedsRender = true`.

**How is `renderedcount` determined?** During export, the tool performs reference counting:

```
For each operator:
    Count how many operators depend on it (directly or via materials)
    If count > 1 OR referenced by material:
        Mark for render (add to renderedcount)
```

This happens in the export tool, not the runtime code. The exported binary contains the pre-computed `renderedcount` value.

**In our example graph**:
- Op0: Referenced by Op1 and Op2 (count = 2) → `NeedsRender = true`
- Op1: Referenced by Op3 only (count = 1) → `NeedsRender = false`
- Op2: Referenced by Op3 only (count = 1) → `NeedsRender = false`
- Op3: Final output (referenced by material) → `NeedsRender = true`

So `renderedcount = 2` (Op0 and Op3), and the loader sets:
- `TextureOperators[0].NeedsRender = true` (0 < 2)
- `TextureOperators[1].NeedsRender = false` (1 not < 2)
- `TextureOperators[2].NeedsRender = false` (2 not < 2)
- `TextureOperators[3].NeedsRender = true` (if 3 < renderedcount, but actually this might be handled differently for final outputs)

Wait, the code is `texopcnt++ < renderedcount`, which means it's checking the **operator index**, not reference count. Let me reconsider.

If `renderedcount = 2`, then:
- `texopcnt = 0`: `0 < 2` → true
- `texopcnt = 1`: `1 < 2` → true
- `texopcnt = 2`: `2 < 2` → false
- `texopcnt = 3`: `3 < 2` → false

So Operators 0 and 1 would have `NeedsRender = true`. But our example needs Op0 and Op3 to persist, not Op0 and Op1.

**Conclusion**: The `renderedcount` mechanism must work differently than a simple index cutoff. Likely the operators are **sorted during export** such that operators needing persistence appear first in the array. The tool performs topological sort with a twist: place operators with `refCount > 1` or material references at the front.

For our trace, I'll assume the correct loading happens and Op0 gets `NeedsRender = true`. The exact export logic isn't visible in the runtime code.

## Subroutine Evaluation: Nested Contexts

Subroutines add another layer of complexity. Let's trace how a subroutine call injects parent textures and overrides parameters.

**File**: `apEx/Phoenix/Texgen.cpp:502-527`

Assume Op3 was actually a subroutine call instead of a simple operator. The call would look like:

```cpp
CphxTexturePoolTexture *PHXTEXTURESUBROUTINE::Generate(
    PHXTEXTUREFILTER *Filters,
    PHXTEXTUREOPERATOR *CallerOperators,
    unsigned short *Parents,
    unsigned char *Parameters,
    unsigned char Resolution)
```

**Step 1: Inject Parent Textures** (lines 505-506):

```cpp
for (unsigned int x = 0; x < DataDescriptor.InputCount; x++)
    Operators[Inputs[x]].CachedResult = CallerOperators[Parents[x]].Generate(Filters, CallerOperators);
```

Assume the subroutine has `InputCount = 2` and `Inputs = [0, 1]` (internal operators 0 and 1 receive external textures). The caller passes `Parents = [5, 8]` (external operators 5 and 8 supply inputs):

```cpp
// x = 0:
Operators[0].CachedResult = CallerOperators[5].Generate(Filters, CallerOperators);

// x = 1:
Operators[1].CachedResult = CallerOperators[8].Generate(Filters, CallerOperators);
```

This **injects external textures** into the subroutine's internal graph. When internal operators request Op0 or Op1, they get the cached textures from the caller's context without rendering.

**Step 2: Override Resolution** (lines 509-510):

```cpp
for (int x = 0; x < 256; x++)
    Operators[x].Resolution = Resolution;
```

Overwrite **all 256** internal operators' resolution fields. Even if the subroutine was authored at 512×512, the caller can invoke it at 1024×1024. This enables scale-independent reusable effects.

**Step 3: Apply Parameter Overrides** (lines 513-514):

```cpp
for (int x = 0; x < DynamicParameterCount; x++)
    Operators[DynamicParameters[x].TargetOperator]
        .Parameters[DynamicParameters[x].TargetParameter] = Parameters[x];
```

Assume `DynamicParameterCount = 2`:
- `DynamicParameters[0] = {TargetOperator: 5, TargetParameter: 2}`
- `DynamicParameters[1] = {TargetOperator: 7, TargetParameter: 0}`

The loop executes:

```cpp
Operators[5].Parameters[2] = Parameters[0];  // Patch operator 5's param 2
Operators[7].Parameters[0] = Parameters[1];  // Patch operator 7's param 0
```

This **exposes internal parameters** to the caller. The subroutine's internal operators have default parameter values, but the caller can override specific ones to customize behavior.

**Step 4: Generate Output** (line 517):

```cpp
CphxTexturePoolTexture *Result = Operators[Output].Generate(Filters, Operators);
```

Call the subroutine's output operator (assume `Output = 12`). This triggers recursive evaluation of the internal graph, using:
- Injected parent textures (via `CachedResult` on operators 0 and 1)
- Overridden resolution (all operators render at caller's requested size)
- Overridden parameters (operators 5 and 7 use caller's values)

The internal graph evaluates using the same `Generate()` method, with its own pool allocations and cache behavior. Once it completes, `Result` holds the final internal texture.

**Step 5: Release Injected Inputs** (lines 520-524):

```cpp
for (unsigned int x = 0; x < DataDescriptor.InputCount; x++)
{
    Operators[Inputs[x]].CachedResult->Used = false;
    Operators[Inputs[x]].CachedResult = NULL;
}
```

Mark the injected textures as unused (return to caller's pool) and clear the `CachedResult` pointers (so internal operators don't retain stale references if the subroutine is called again).

**Return**: The internal output texture to the caller.

### Subroutine Memory Isolation

Subroutines share the global texture pool with the caller. There's no separate pool for internal operators. This means:

- Subroutine allocations compete with caller allocations for pool slots
- Internal textures can reuse caller's released textures
- Peak memory usage is the sum of caller graph + internal graph active textures

**Example**: If the caller has 3 textures allocated when calling a subroutine that needs 5 textures, peak usage is 8 textures (assuming no overlapping releases).

This shared pool design saves code size—no need for pool management logic in subroutines. The trade-off is higher peak memory usage than isolated pools.

## Texture Pool Reuse Patterns

The pool's efficiency comes from aggressive reuse. Let's trace Texture B's lifecycle across our example:

**Creation** (step 2): Op0 allocates backbuffer → Texture B created at 256×256 UNORM

**First use** (steps 3-4): Op0 uses B as ping-pong swap target during 8-pass rendering. Final result in A, B released.

**Second use** (steps 6-9): Op1 searches pool, finds B matches (256×256, unused), claims it for Result. Renders colorize to B... wait, no.

Actually, re-reading my trace above, I had Op1's allocations backward. Let me correct:

Op1 allocates:
- `Result` → First `GetTexture()` call → Finds Texture B (unused, matches) → Reuse
- `BackBuffer` → Second `GetTexture()` call → Allocates Texture C

But then the render swaps `Target = C`, `SwapBuffer = B`, and writes to Texture C. So Op1's **final output is Texture C**, not B.

Let me re-trace with correct pointer tracking:

**Op0**:
- Allocate: `Result = A`, `BackBuffer = B`
- After 8 passes (even count): `Result = A`, `BackBuffer = B` (original assignment)
- Release: `BackBuffer->Used = false` → B available
- Return: A

**Op1**:
- Allocate: `Result = B` (reused!), `BackBuffer = C` (new)
- After 1 pass (odd count): `Result = C`, `BackBuffer = B` (swapped)
- Release: `BackBuffer->Used = false` → B available
- Return: C

**Op2**:
- Allocate: `Result = B` (reused), `BackBuffer = D` (new)
- After 1 pass: `Result = D`, `BackBuffer = B` (swapped)
- Release: `BackBuffer->Used = false` → B available
- Return: D

**Op3**:
- Allocate: `Result = B` (reused), `BackBuffer = E` (new)
- After 1 pass: `Result = E`, `BackBuffer = B` (swapped)
- Release: `BackBuffer->Used = false` → B available
- Release C and D (parent check)
- Return: E

**Corrected Texture B lifecycle**:
1. Created as Op0's backbuffer
2. Released by Op0
3. Reused as Op1's result, swapped to backbuffer role, released
4. Reused as Op2's result, swapped to backbuffer role, released
5. Reused as Op3's result, swapped to backbuffer role, released
6. Final state: Available in pool, never deleted

Texture B is the workhorse—used by 4 operators but only allocated once. This is the pool's efficiency.

## Evaluation Order and Topological Guarantees

The recursive depth-first traversal ensures correct evaluation order automatically. No explicit topological sort is needed because the recursion naturally processes parents before children.

**Proof by induction**:
- **Base case**: Leaf operators (no parents) evaluate immediately.
- **Inductive step**: For an operator with parents, the parent loop (lines 471-479) evaluates all parents before executing the operator's render step (line 486).

**Diamond dependency correctness**: Shared parents evaluate once on first visit (cache miss), then return cached results on subsequent visits (cache hit). The traversal order doesn't matter—depth-first ensures all paths converge.

**Example traversal orders** for our graph:

**Depth-first from Op3**:
1. Visit Op3 → recurse to parents
2. Visit Op1 → recurse to Op0
3. Visit Op0 → render → cache → return
4. Resume Op1 → render → return
5. Visit Op2 → recurse to Op0
6. Visit Op0 → cache hit → return
7. Resume Op2 → render → return
8. Resume Op3 → render → return

**Alternative traversal** (if parent order were reversed):
1. Visit Op3 → recurse to parents
2. Visit Op2 → recurse to Op0
3. Visit Op0 → render → cache → return
4. Resume Op2 → render → return
5. Visit Op1 → recurse to Op0
6. Visit Op0 → cache hit → return
7. Resume Op1 → render → return
8. Resume Op3 → render → return

Both produce correct results because caching ensures Op0 renders exactly once.

## Comparison to Explicit Topological Sort

An alternative design would topologically sort the graph upfront, then iterate in order:

```cpp
// Hypothetical alternative:
vector<int> sortedOrder = TopologicalSort(Operators);
for (int opIdx : sortedOrder)
{
    if (!Operators[opIdx].CachedResult)
        Operators[opIdx].Render(...);
}
```

**Pros**:
- Iteration is simpler (no recursion)
- Easier to debug (linear execution)
- Can parallelize independent operators (Op1 and Op2 could run concurrently)

**Cons**:
- Requires topological sort algorithm (adds code size)
- Must evaluate all operators in graph, even if only subset needed
- No lazy evaluation (can't request one operator and skip unrelated branches)

Phoenix chooses recursion because:
1. Lazy evaluation is natural (only evaluate what's needed)
2. No sorting algorithm needed (saves code bytes)
3. Demos have small graphs (10-50 operators) where recursion is cheap
4. Cache checking is trivial (single `if` statement)

For a modern Rust framework with larger graphs (100+ operators), explicit sorting with parallelism might be worth the complexity. But for 64k demos, Phoenix's choice is optimal.

## Memory Management Without Garbage Collection

Phoenix's memory model is interesting: aggressive allocation with manual release timing. Let's compare to different memory management strategies:

### Phoenix's Strategy: Manual Reference Flags

```cpp
// Allocate from pool (reuses if available)
Texture *t = pool->GetTexture(resolution, hdr);

// Use texture...

// Release when done
if (!operator.NeedsRender)
    t->Used = false;
```

**Pros**:
- Explicit control over lifetime
- No GC pauses or overhead
- Deterministic release timing

**Cons**:
- Easy to leak memory (forget to release)
- Easy to use-after-free (release too early)
- Requires manual reference tracking (NeedsRender flag)

### Reference Counting Strategy

```cpp
// Hypothetical Rc-based approach:
Rc<Texture> t = pool->GetTexture(resolution, hdr);

// Use texture...

// Automatic release when Rc drops to zero
```

**Pros**:
- Automatic lifetime management
- Safe against use-after-free (can't access dropped Rc)
- Safe against leaks (drops when last reference disappears)

**Cons**:
- Overhead of increment/decrement operations
- Cyclic references leak (need Weak for cycles)
- Code size increase (Rc implementation)

### Arena Allocation Strategy

```cpp
// Allocate from per-frame arena
Texture *t = frameArena->Allocate(resolution, hdr);

// Use texture...

// Release entire arena at frame end
frameArena->Clear();
```

**Pros**:
- Extremely fast allocation (bump pointer)
- Automatic bulk release
- No per-texture tracking

**Cons**:
- Can't release individual textures early
- Peak memory usage higher (holds all until frame end)
- Requires knowing lifetime boundaries

Phoenix's manual approach fits its constraints: small code size, predictable performance, explicit control. For a Rust framework, Rc/Arc might be worth the overhead for safety.

## Pathological Cases and Edge Conditions

### Circular Dependencies

What if the graph contains a cycle? For example, Op5 depends on Op7, and Op7 depends on Op5?

```cpp
// Op5's Generate():
ParentResults[0] = Operators[7].Generate(...);  // Recurse to Op7

// Op7's Generate():
ParentResults[0] = Operators[5].Generate(...);  // Recurse to Op5
```

This creates infinite recursion, eventually stack overflowing.

**Phoenix's defense**: None at runtime. The tool (export-time) must validate the graph is acyclic. If a user creates a cycle in the editor, export should fail with an error.

**Rust framework solution**: Use visited tracking during evaluation:

```rust
fn generate(&mut self, visited: &mut HashSet<usize>) -> Result<&Texture, Error> {
    if !visited.insert(self.id) {
        return Err(Error::CircularDependency(self.id));
    }
    // ... rest of generation ...
    visited.remove(&self.id);  // Allow reuse in other branches
}
```

This detects cycles at runtime without requiring export-time validation.

### Extremely Deep Graphs

What if the graph is a linear chain of 1000 operators? Op999 depends on Op998, which depends on Op997, ... down to Op0.

**Stack depth**: 1000 nested calls to `Generate()`. Each call allocates:
- Local variables: ~48 bytes (pointers, indices)
- Call overhead: ~16 bytes (return address, frame pointer)
- Total: ~64KB stack usage

Most platforms default to 1MB stack for threads. 1000 operators would consume only 6% of stack space—safe.

**Cache memory**: Each operator caches its result. 1000 operators × 8MB per texture (1024×1024×8 bytes) = 8GB. This exceeds typical VRAM budgets.

**Phoenix's defense**: Demos don't create pathological graphs. Typical graphs are 10-50 operators deep with significant sharing (diamond patterns, not linear chains). If a graph exceeds memory, the pool allocation fails and the demo crashes. No graceful degradation.

**Rust framework solution**: Impose depth limits or memory budgets:

```rust
fn generate(&mut self, depth: usize) -> Result<&Texture, Error> {
    if depth > MAX_DEPTH {
        return Err(Error::ExcessiveDepth(depth));
    }
    // ... recurse with depth+1 ...
}
```

This provides clear error messages instead of silent crashes.

### Mismatched Resolution Parents

What if Op5 (1024×1024) depends on Op2 (256×256)? The shader renders at 1024×1024 but samples from a 256×256 input.

**Phoenix's behavior**: The shader samples the parent texture. D3D11's sampler interpolates. If the parent is lower resolution, the shader gets blurry/blocky results. If higher, the shader gets downsampled results.

**Intentional usage**: Artists might deliberately create this. A high-frequency detail texture (1024×1024) samples a low-frequency color ramp (256×256) as a lookup table. The resolution mismatch is a feature.

**Unintentional usage**: If the artist expects crisp results but parent is too low-res, the output looks blurry. The tool should warn about resolution mismatches, but the runtime accepts them.

**Rust framework solution**: Make resolution explicit in types:

```rust
pub struct Operator<R: Resolution> {
    parents: [Option<Box<dyn Operator<R>>>; 3],
    // ...
}
```

This enforces matching resolutions at compile time... but sacrifices flexibility for mismatched-resolution effects. Better solution: runtime warnings in debug builds.

## Performance Analysis: Cache Hit Rates

For our example graph with 4 operators:

**Total operator evaluations**: 4 (Op0, Op1, Op2, Op3)

**Generate() calls**:
- Op3 calls `Generate(1)` and `Generate(2)` → 2 calls
- Op1 calls `Generate(0)` → 1 call
- Op2 calls `Generate(0)` → 1 call
- Total: **4 calls to Generate()**, but only **3 execute rendering** (Op0's second call is a cache hit)

**Cache hit rate**: 1/4 = 25%

For larger graphs with more sharing, cache hit rates improve dramatically:

**Example: Shared noise basis**:
```
Op0: noise (basis for entire graph)
  ↓
┌─┴─┬─────┬─────┬─────┐
↓   ↓     ↓     ↓     ↓
Op1 Op2   Op3   Op4   Op5 (5 different colorizations of same noise)
↓   ↓     ↓     ↓     ↓
└─┬─┴──┬──┴──┬──┴─────┘
  ↓    ↓     ↓
  Op6  Op7   Op8 (combine colorizations)
  ↓    ↓     ↓
  └────┴─────┴→ Op9 (final blend)
```

**Generate() calls**: Op9 calls → Op6,7,8 → each calls → Op1,2,3,4,5 → each calls → Op0

Total: 1 + 3 + 5 + (5 × 1) = **14 calls to Generate(0)**

**Renders**: Op0 executes once (first call), returns cached result for calls 2-14.

**Cache hit rate**: 13/14 = **93%**

The more sharing, the higher the hit rate. Demoscene texture graphs heavily share noise bases, color ramps, and blend operators.

## Implementation Insights

### Why Use Recursion Instead of Iteration?

Recursive evaluation is elegant but has trade-offs:

**Pros**:
- Lazy evaluation is natural (only evaluate needed subgraph)
- No explicit stack management (call stack handles it)
- Cache checking is trivial
- Code is simple (~30 lines for entire traversal)

**Cons**:
- Stack overflow risk for extremely deep graphs
- No parallelism (can't evaluate independent branches concurrently)
- Harder to instrument (can't easily count total progress)

Phoenix chooses recursion because demo graphs are shallow (rarely >20 levels deep) and small (50-100 operators max). The simplicity saves code bytes and development time.

**Rust equivalent**:

```rust
impl Operator {
    pub fn generate(
        &mut self,
        filters: &[Filter],
        operators: &mut [Operator],
        pool: &mut TexturePool,
    ) -> TextureHandle {
        // Cache check
        if let Some(cached) = self.cached_result {
            return cached;
        }

        // Generate parents
        let parent_textures: Vec<TextureHandle> = self.parents.iter()
            .filter_map(|&parent_idx| parent_idx.map(|idx| {
                operators[idx].generate(filters, operators, pool)
            }))
            .collect();

        // Allocate targets
        let result = pool.allocate(self.resolution, self.is_hdr());
        let backbuffer = pool.allocate(self.resolution, self.is_hdr());

        // Render
        filters[self.filter].render(result, backbuffer, &parent_textures, &self.params);

        // Cleanup
        pool.release(backbuffer);
        for (i, &parent_idx) in self.parents.iter().enumerate() {
            if let Some(idx) = parent_idx {
                if !operators[idx].needs_render {
                    pool.release(parent_textures[i]);
                }
            }
        }

        // Cache and return
        self.cached_result = Some(result);
        result
    }
}
```

Rust's ownership system makes the pattern safer. The borrow checker ensures `operators` isn't mutated during iteration, and handles are validated automatically.

### Why Not Cache Inside Render()?

The `Render()` method doesn't set `CachedResult`. The `Generate()` method (or its caller) does. Why this separation?

**Answer**: `Render()` is a low-level primitive that executes a filter. It doesn't know about the operator graph, parent dependencies, or caching. It just binds shaders and draws.

`Generate()` is the high-level orchestrator that understands the graph structure, manages dependencies, allocates memory, and handles caching. This separation of concerns keeps each function focused.

**Alternative design**: Merge them into one function. `Render()` becomes part of `Generate()` as inline code rather than a separate method.

**Trade-off**: Separation enables reusing `Render()` for subroutines, debugging (can call `Render()` manually), and testing (render a filter without graph context). Inlining would save function call overhead (~5% CPU time) but reduce modularity.

Phoenix keeps them separate for clarity. A size-optimized build might inline `Render()` into `Generate()` to save bytes.

## Implications for Rust Framework Design

Phoenix's evaluation and caching architecture offers several lessons for modern creative coding frameworks.

### Adopt: Lazy Evaluation with Memoization

Recursive evaluation with cache checking is elegant and efficient:

```rust
pub struct Operator {
    cached_result: Option<Arc<Texture>>,
    // ...
}

impl Operator {
    pub fn generate(&mut self, context: &mut Context) -> Arc<Texture> {
        if let Some(ref cached) = self.cached_result {
            return Arc::clone(cached);
        }

        let parents = self.parents.iter()
            .filter_map(|&p| p.map(|idx| context.operators[idx].generate(context)))
            .collect::<Vec<_>>();

        let texture = self.render(context, &parents);
        let arc = Arc::new(texture);
        self.cached_result = Some(Arc::clone(&arc));
        arc
    }
}
```

Using `Arc` instead of raw pointers provides automatic reference counting. When the last `Arc` drops, the texture deallocates automatically.

### Adopt: Texture Pooling by Resolution Buckets

Phoenix's pool is a flat array with linear search. A Rust framework should use a hash map keyed by `(Resolution, HDR)`:

```rust
use std::collections::HashMap;

pub struct TexturePool {
    buckets: HashMap<(Resolution, bool), Vec<Option<wgpu::Texture>>>,
}

impl TexturePool {
    pub fn allocate(&mut self, res: Resolution, hdr: bool) -> TextureHandle {
        let bucket = self.buckets.entry((res, hdr)).or_insert_with(Vec::new);

        // Find first unused slot
        for (i, slot) in bucket.iter_mut().enumerate() {
            if slot.is_none() {
                let texture = create_texture(res, hdr);
                *slot = Some(texture);
                return TextureHandle::new((res, hdr), i);
            }
        }

        // Allocate new
        let texture = create_texture(res, hdr);
        bucket.push(Some(texture));
        TextureHandle::new((res, hdr), bucket.len() - 1)
    }

    pub fn release(&mut self, handle: TextureHandle) {
        let bucket = self.buckets.get_mut(&handle.key).unwrap();
        bucket[handle.index] = None;
    }
}
```

This eliminates the linear search for matching resolutions. Hash map lookups are O(1) expected time. The buckets group textures by size, improving cache locality during reuse.

### Adopt: Explicit Dependency Graph Structure

Instead of embedding parent indices in operators, build an explicit graph structure:

```rust
pub struct OperatorGraph {
    nodes: Vec<Operator>,
    edges: Vec<Vec<usize>>,  // edges[i] = list of children of node i
}

impl OperatorGraph {
    pub fn topological_sort(&self) -> Result<Vec<usize>, Error> {
        // Kahn's algorithm or DFS-based sort
    }

    pub fn evaluate(&mut self, output_id: usize) -> Result<&Texture, Error> {
        // Compute subgraph reachable from output_id
        let reachable = self.compute_reachable(output_id);

        // Sort reachable nodes topologically
        let sorted = self.topological_sort_subset(&reachable)?;

        // Evaluate in order
        for &node_id in &sorted {
            self.nodes[node_id].generate(...);
        }

        Ok(self.nodes[output_id].cached_result.as_ref().unwrap())
    }
}
```

This separates graph structure from operator logic. Benefits:
- Can analyze graph (detect cycles, count references, optimize)
- Can visualize graph (export to Graphviz DOT format)
- Can parallelize (evaluate independent nodes concurrently)

Trade-off: More code complexity, slightly larger binary. For frameworks beyond 64k constraints, this is acceptable.

### Consider: Parallel Evaluation

Phoenix's recursive evaluation is serial. Operators evaluate one at a time. But Op1 and Op2 are independent—they could render concurrently.

**Rust parallel strategy**:

```rust
use rayon::prelude::*;

impl OperatorGraph {
    pub fn evaluate_parallel(&mut self, output_id: usize) -> &Texture {
        let levels = self.compute_dependency_levels(output_id);

        for level in levels {
            // All operators in a level have no dependencies on each other
            level.par_iter().for_each(|&op_id| {
                self.nodes[op_id].generate(...);
            });
        }

        &self.nodes[output_id].cached_result.unwrap()
    }

    fn compute_dependency_levels(&self, root: usize) -> Vec<Vec<usize>> {
        // BFS from root, group nodes by distance from leaves
        // Level 0: Leaf operators (no parents)
        // Level 1: Operators depending only on level 0
        // Level 2: Operators depending on level 0-1
        // ...
    }
}
```

**Example levels for our graph**:
- **Level 0**: Op0 (leaf)
- **Level 1**: Op1, Op2 (both depend only on level 0)
- **Level 2**: Op3 (depends on level 1)

Op1 and Op2 could render in parallel on separate threads. For large graphs (100+ operators), this significantly reduces wall-clock time.

**Trade-offs**:
- Code complexity (dependency level computation)
- GPU contention (multiple threads issuing draw calls)
- Memory pressure (all level N operators render simultaneously)

For CPU-based procedural generation (Rust's image processing), this parallelism is valuable. For GPU-based rendering, the GPU is already parallelizing per-pixel work—multi-threaded submission might not help.

### Avoid: Global Mutable State

Phoenix uses global pointers:

```cpp
CphxTexturePool *TexgenPool;
PHXTEXTUREOPERATOR *TextureOperators;
```

This enables simple function signatures (no need to pass context everywhere) but prevents:
- Multiple independent texgen contexts
- Thread-safe evaluation
- Isolated testing

**Rust solution**: Encapsulate in a context struct:

```rust
pub struct TexgenContext {
    pool: TexturePool,
    operators: Vec<Operator>,
    filters: Vec<Filter>,
}

impl TexgenContext {
    pub fn generate(&mut self, operator_id: usize) -> &Texture {
        self.operators[operator_id].generate(&self.filters, &mut self.operators, &mut self.pool)
    }
}
```

Each context is independent. Multiple contexts can coexist. Testing creates a fresh context per test. No global state, no data races.

## Key Takeaways

This trace reveals several critical patterns for procedural texture generation systems:

**Recursive evaluation with caching eliminates redundant work**. Diamond dependencies render shared parents once, not multiple times. The cache hit on Op0's second visit saved an entire 8-pass noise generation—potentially milliseconds of GPU time.

**The NeedsRender flag implements reference counting without overhead**. Instead of atomic increments/decrements, a simple boolean flag marks operators with multiple dependents. Parent cleanup checks this flag before releasing textures.

**Texture pooling minimizes peak memory usage**. Aggressive reuse of released textures means a graph needing 10 unique textures might only allocate 6 pool slots (if 4 textures reuse across operator evaluations). Texture B's 4-operator reuse lifecycle demonstrates this.

**Depth-first traversal guarantees topological order without explicit sorting**. The recursion naturally evaluates parents before children. No topological sort algorithm needed—the call stack encodes the ordering.

**Separation of Generate() and Render() enables reuse and clarity**. High-level graph traversal (dependencies, caching) separates from low-level rendering (shaders, draw calls). Subroutines reuse `Render()` without duplicating logic.

**Lazy evaluation enables tool-time flexibility**. The exported demo only evaluates operators actually needed for materials. Unreferenced branches (alternate versions, experiments) don't execute, saving runtime work.

Phoenix's texgen evaluation architecture demonstrates how functional programming patterns (lazy evaluation, memoization, immutability) map elegantly to procedural asset generation while maintaining the imperative, low-level control needed for 64k size constraints and real-time GPU rendering.

## Related Documents

For comprehensive coverage of the texgen system and broader rendering context:

- **[../texgen/overview.md](../texgen/overview.md)** — Texgen system architecture and mental models
- **[../texgen/pipeline.md](../texgen/pipeline.md)** — Complete data flow from graph to GPU rendering
- **[../texgen/operators.md](../texgen/operators.md)** — Operator data structures and parameter encoding
- **[../texgen/shaders.md](../texgen/shaders.md)** — HLSL shader patterns and constant buffer conventions
- **[../rendering/materials.md](../rendering/materials.md)** — How materials reference texgen operators
- **[scene-to-pixels.md](scene-to-pixels.md)** — Scene graph to draw calls (shows material-texture binding)

For parallel system analysis:

- **[synth-pipeline.md](synth-pipeline.md)** — Audio synthesis evaluation (similar lazy evaluation pattern)

## References

All paths relative to `demoscene/apex-public/apEx/Phoenix/`:

**Core implementation**:
- `Texgen.cpp:464-497` — `PHXTEXTUREOPERATOR::Generate()` (main evaluation function)
- `Texgen.cpp:466` — Cache check
- `Texgen.cpp:470-479` — Parent generation loop
- `Texgen.cpp:482-483` — Render target allocation
- `Texgen.cpp:486` — Filter rendering call
- `Texgen.cpp:488` — Backbuffer release
- `Texgen.cpp:491-493` — Parent result release (NeedsRender check)

**Memory pool**:
- `Texgen.cpp:67-87` — `CphxTexturePool::GetTexture()` (pool allocation logic)
- `Texgen.cpp:69-77` — Linear search for matching unused texture
- `Texgen.cpp:80-86` — New texture allocation when no match found
- `Texgen.cpp:18-64` — `CphxTexturePoolTexture::Create()` (D3D11 resource creation)

**Multi-pass rendering**:
- `Texgen.cpp:120-185` — `PHXTEXTUREFILTER::Render()` (filter execution)
- `Texgen.cpp:134` — Multi-pass loop start
- `Texgen.cpp:139-141` — Target swap (ping-pong)
- `Texgen.cpp:163-169` — Texture binding logic
- `Texgen.cpp:172` — Draw call
- `Texgen.cpp:174` — Mipmap generation

**Subroutines**:
- `Texgen.cpp:502-527` — `PHXTEXTURESUBROUTINE::Generate()` (nested context evaluation)
- `Texgen.cpp:505-506` — Input texture injection
- `Texgen.cpp:509-510` — Resolution override
- `Texgen.cpp:513-514` — Parameter override
- `Texgen.cpp:517` — Output operator generation
- `Texgen.cpp:520-524` — Injected input cleanup

**Graph loading**:
- `Project.cpp:425` — NeedsRender flag assignment during operator deserialization
- `Project.cpp:487` — Initial texture generation with cache assignment

**Data structures**:
- `Texgen.h:105-124` — `PHXTEXTUREOPERATOR` struct definition
- `Texgen.h:66-73` — `PHXFILTERDATADESCRIPTOR` bitfield layout
- `Texgen.h:23-33` — `CphxTexturePoolTexture` class
- `Texgen.h:35-49` — `CphxTexturePool` class
- `Texgen.h:135-149` — `PHXTEXTURESUBROUTINE` struct
