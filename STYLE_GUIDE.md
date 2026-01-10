# Documentation Style Guide

> *Guidelines for writing clear, conceptual technical documentation*

---

## Purpose

This guide establishes standards for Tooll3 Editor documentation. Good documentation helps readers build **mental models** of systems, not just understand code syntax. Every chapter should answer: "Why does this exist, and how should I think about it?"

---

## Core Principles

### 1. Lead with the Problem

**Don't** jump straight into code or API descriptions.

**Do** start by explaining what problem the system solves. Make the reader care about the solution by first making them understand the challenge.

```markdown
❌ Bad:
"The GenericFactory class uses a ConcurrentDictionary to map types to factory functions."

✅ Good:
"Imagine you need to create different renderers for 20+ output types. A giant switch
statement would be unmaintainable. The factory pattern solves this by letting each
type register its own renderer, keeping the creation logic decentralized and extensible."
```

### 2. Explain the Why Before the What

Every design decision exists for a reason. Help readers understand the trade-offs.

```markdown
❌ Bad:
"Use ConditionalWeakTable for per-view state."

✅ Good:
"The obvious approach - a Dictionary<string, ViewSettings> - has a subtle problem:
when a view closes, its viewId string is no longer used, but the dictionary still
holds a reference. Memory leak. ConditionalWeakTable solves this by integrating with
the garbage collector - when the key is collected, the value is automatically removed."
```

### 3. Build Mental Models with Analogies

Connect unfamiliar concepts to familiar ones.

```markdown
✅ Good examples:
- "Think of the factory like a plugin system - the core asks for a renderer,
   and gets back a specialized component without knowing the details."
- "The template method is like a recipe with blanks: the base class defines
   the steps, subclasses fill in the specifics."
- "Per-view state is like having separate notepads for each window -
   what you write in one doesn't affect the others."
```

### 4. Trace Concrete Data Flow

Abstract descriptions are hard to follow. Walk through a specific example.

```markdown
❌ Bad:
"The factory creates OutputUi instances based on type."

✅ Good:
"Let's trace what happens when displaying a float output:

1. The editor sees an output of type `float`
2. It asks: OutputUiFactory.CreateFor(typeof(float))
3. The factory looks up 'float' in its registry, finds FloatOutputUi
4. A new FloatOutputUi instance is created and returned
5. This instance is associated with the specific output slot"
```

### 5. Code Comes After Concepts

Readers need to understand *what they're looking at* before seeing code.

```markdown
❌ Bad structure:
```csharp
public void DrawValue(ISlot slot, ...) { ... }
```
"This method draws the output value."

✅ Good structure:
"Every OutputUi must be able to draw its value. The base class orchestrates
this in two phases: first optionally recomputing the value (running the operator),
then delegating to the specialized drawing logic. Here's what that looks like:"
```csharp
public void DrawValue(ISlot slot, ...) { ... }
```
```

### 6. Use Conversational Language

Write as if explaining to a colleague, not documenting for a compiler.

```markdown
✅ Good phrases:
- "You might wonder why..."
- "The key insight is..."
- "Here's where it gets interesting..."
- "This seems simple, but there's a catch..."
- "Let's think about what happens when..."
- "The naive approach would be..."
```

---

## Structure Guidelines

### Chapter Structure

Each chapter should follow this general flow:

1. **Opening hook** - A one-line summary that creates curiosity
2. **The problem** - What challenge does this solve? Why should I care?
3. **The mental model** - How should I think about this system?
4. **The solution** - How it works, conceptually first, then in code
5. **Concrete examples** - Trace through real scenarios
6. **Edge cases / gotchas** - What could go wrong, what's tricky
7. **Next steps** - Where to go from here

### Section Headings

Use descriptive headings that tell a story:

```markdown
❌ Bad headings:
## GenericFactory
## Methods
## Usage

✅ Good headings:
## The Problem: Type Dispatch Without Giant Switch Statements
## How the Factory Knows What to Create
## What Happens When You Request an Unknown Type
```

### Code Blocks

- Introduce code with context: "Here's what that looks like in practice:"
- Keep code blocks focused - show only what's relevant
- Add comments for non-obvious lines
- Follow code with explanation of key points

### Diagrams

Use ASCII diagrams to visualize:
- Data flow
- System architecture
- State transitions
- Object relationships

```
✅ Good: ASCII diagrams that render anywhere
┌─────────────┐     ┌─────────────┐
│   Request   │────▶│   Factory   │
└─────────────┘     └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  Renderer   │
                    └─────────────┘
```

---

## Quality Checklist

Use this checklist to evaluate documentation quality:

### Conceptual Clarity

- [ ] Does the chapter explain WHY before WHAT?
- [ ] Is there a clear problem statement?
- [ ] Are design decisions explained, not just described?
- [ ] Would a reader unfamiliar with the code understand the mental model?
- [ ] Are analogies used to connect to familiar concepts?

### Flow and Structure

- [ ] Does the chapter follow a logical progression?
- [ ] Is there a concrete example traced step-by-step?
- [ ] Does code appear AFTER conceptual explanation?
- [ ] Are section headings descriptive (not just nouns)?
- [ ] Is there a clear "what's next" at the end?

### Language and Tone

- [ ] Is the language conversational, not robotic?
- [ ] Are sentences varied in length and structure?
- [ ] Is jargon explained when introduced?
- [ ] Does it read like explaining to a colleague?

### Technical Accuracy

- [ ] Are code examples correct and tested?
- [ ] Are file paths and class names accurate?
- [ ] Are edge cases and gotchas mentioned?
- [ ] Is the scope clear (what's covered vs. not)?

---

## Anti-Patterns to Avoid

### The API Dump

❌ Just listing methods and parameters without context.

```markdown
Bad:
"DrawValue(slot, context, viewId, recompute) - Draws the value.
- slot: The slot
- context: The context
- viewId: The view ID
- recompute: Whether to recompute"
```

### The Code-First Approach

❌ Starting with code before readers know what they're looking at.

### The Passive Voice Wall

❌ "The value is computed by the slot, which is then passed to the renderer, where it is drawn."

✅ "The slot computes the value. The renderer draws it."

### The Jargon Barrier

❌ Using terms without explanation: "The ConditionalWeakTable ephemerons enable non-preventing reference semantics."

✅ "ConditionalWeakTable has special garbage collector integration - when its keys are collected, the values automatically disappear too."

### The Missing Why

❌ "Use pattern X" without explaining why pattern X and not Y.

---

## Examples: Before and After

### Example 1: Factory Pattern

**Before (terse, code-focused):**

```markdown
## GenericFactory

```csharp
public sealed class GenericFactory<T>
{
    private readonly ConcurrentDictionary<Type, Func<T>> _entries = new();
    public T CreateFor(Type type) { ... }
}
```

The factory creates instances based on type.
```

**After (narrative, conceptual):**

```markdown
## The Problem: Creating the Right Renderer Without a Giant Switch

When the editor needs to display an output, it faces a question: which renderer
should handle this type? A float needs a curve plotter. A texture needs an
image viewer. A Command needs an entire GPU pipeline.

The naive solution is a giant switch statement:

```csharp
if (type == typeof(float)) return new FloatOutputUi();
else if (type == typeof(Texture2D)) return new Texture2dOutputUi();
// ... 20 more cases
```

This is fragile. Every new type means modifying this central function. The
logic for each type is scattered. Testing is painful.

The factory pattern inverts this: instead of one place knowing about all types,
each type registers itself. The factory just maintains the registry and performs
lookups.

Think of it like a phone book. Instead of one person memorizing everyone's
number, each person registers their own entry. The phone book just handles
the lookup.
```

### Example 2: Per-View State

**Before:**

```markdown
## View Settings

```csharp
private static readonly ConditionalWeakTable<string, ViewSettings> _viewSettings = [];
```

Per-view state is stored in a ConditionalWeakTable.
```

**After:**

```markdown
## The Challenge: Multiple Views, Independent State

Picture this: you have the same float output displayed in three places - the
graph view, a pop-out panel, and the output window. Each should have its own
curve history. When you pause one view, the others keep running.

This means each view needs independent state. The obvious solution:

```csharp
private Dictionary<string, ViewSettings> _settings = new();
```

But there's a subtle problem. When a view closes, its viewId string is no longer
used anywhere in the program. But our dictionary still holds a reference to the
settings. The garbage collector can't clean it up. Memory leak. Over time, the
dictionary accumulates ghost entries for views that no longer exist.

Enter ConditionalWeakTable - a special collection designed exactly for this
scenario. It integrates with the garbage collector: when a key is collected,
the associated value is automatically removed. No explicit cleanup needed.

This is why OutputUis can be "fire and forget" - you don't need to carefully
track their lifecycle or remember to clean up when views close.
```

---

## File Naming and Organization

- Use numbered prefixes: `01-`, `02-`, etc.
- Use lowercase with hyphens: `factory-pattern.md`, not `FactoryPattern.md`
- Keep related chapters in the same directory
- Create an `00-index.md` for each documentation set
- Update `PROGRESS.md` when completing chapters

---

## Cognitive Load Principles

Based on research from [The Programmer's Brain](https://www.manning.com/books/the-programmers-brain) by Dr. Felienne Hermans.

### The Three Memory Systems

When reading documentation, readers juggle three cognitive systems:

| System | Limit | Your Job as Writer |
|--------|-------|-------------------|
| **Long-Term Memory** | Unlimited | Activate relevant prior knowledge early |
| **Short-Term Memory** | 4-6 items | Don't introduce too many concepts at once |
| **Working Memory** | Very limited | Provide diagrams/tables to offload processing |

### Chunking

Group related information so it's processed as a single unit:

```markdown
❌ Bad (5 separate concepts):
"The Batcher collects draw calls. It sorts by texture. It merges adjacent calls.
It uploads vertex data. It issues GPU commands."

✅ Good (1 chunk):
"The Batcher optimizes rendering by collecting similar draw calls and submitting
them together - like sorting mail by ZIP code before delivery."
```

### Beacons

Use consistent patterns that trigger instant recognition:

| Beacon | Reader Thinks |
|--------|---------------|
| `> Blockquote` | "Status or key callout" |
| `## The Problem:` | "I'll understand why this matters" |
| `file.rs:42` | "I can find this exact location" |
| `1. First... 2. Then...` | "A sequence I can follow" |
| `| Table |` | "Quick reference I can scan" |

### State Tables for Complex Flows

When explaining state changes, externalize them:

```markdown
❌ Hard to process mentally:
"First the path is tessellated into vertices, then those vertices are
collected into a batch, then the batch is uploaded to a buffer, then..."

✅ Easy to scan:
| Stage | Input | Output |
|-------|-------|--------|
| Tessellate | Path commands | Vertices |
| Batch | Vertices | Draw call |
| Upload | Draw call | GPU buffer |
| Draw | GPU buffer | Pixels |
```

### Layer Information (Progressive Disclosure)

Structure documents so readers can stop at their needed depth:

```
README.md           → "What is this?" (2 min)
architecture.md     → "How is it organized?" (10 min)
rendering-pipeline.md → "How does it actually work?" (30 min)
code-traces/        → "Show me the exact code" (60+ min)
```

### Flashcard-Ready Facts

Format key insights for easy extraction:

```markdown
✅ Good (extractable):
> **Key insight:** Mixbox uses a 7-channel latent space because RGB's 3 channels
> can't represent the nonlinear behavior of real pigments.

❌ Bad (buried):
"The system, which was developed to address limitations in traditional
color mixing, employs a representation with seven channels, as opposed to
the conventional three, due to the complex nature of pigment interactions."
```

### Address All Three Confusion Types

When readers struggle, it's usually one of:

| Confusion | Symptom | Your Fix |
|-----------|---------|----------|
| **Knowledge gap** | "What does X mean?" | Define terms, link to glossary |
| **Information gap** | "Where did Y come from?" | Add context, recap earlier points |
| **Processing overload** | "This is too complex" | Add diagram, break into steps |

---

## Summary

Good documentation is about **teaching**, not just **describing**. Every section should help readers build understanding, not just provide reference material.

Ask yourself: "If I knew nothing about this system, would this chapter help me understand *how to think about it*?"

For more on how to effectively read this documentation, see [notes/READING_GUIDE.md](notes/READING_GUIDE.md).

