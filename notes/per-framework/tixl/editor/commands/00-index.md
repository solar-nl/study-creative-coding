# Commands Technical Documentation

> **The undo/redo infrastructure**
>
> *Understanding how Tooll3 makes operations reversible*

**Part of:** [Editor Documentation](../00-architecture.md) | [Progress Tracker](../PROGRESS.md)

---

## About This Documentation

The Commands system provides undo/redo capability for all editor operations in Tooll3. Every modification—adding operators, creating connections, changing parameters—flows through this system.

**Focus:** This documentation set covers the **Symbol Instance Commands**—how node creation from the Symbol Browser integrates with undo/redo.

---

## Documentation Structure

### Symbol Creation Commands

| Chapter | Title | Description |
|---------|-------|-------------|
| [01](01-symbol-commands.md) | Symbol Instance Commands | AddSymbolChildCommand, auto-connection, MacroCommand grouping |

---

## Quick Reference

### Source Location

```
Editor/UiModel/Commands/
├── Graph/
│   ├── AddSymbolChildCommand.cs    (~100 LOC)  Create operator instance
│   ├── AddConnectionCommand.cs     (~80 LOC)   Wire connection
│   └── ...
└── UndoRedoStack.cs                (~200 LOC)  Command history

Editor/Gui/Graph/Legacy/Interaction/
└── SymbolBrowser.cs                            CreateInstance() method
```

### Key Classes at a Glance

| Class | Purpose | LOC |
|-------|---------|-----|
| `AddSymbolChildCommand` | Creates operator instance with undo support | ~100 |
| `AddConnectionCommand` | Wires a single connection with undo support | ~80 |
| `MacroCommand` | Groups multiple commands into single undo step | ~50 |
| `UndoRedoStack` | Manages command history | ~200 |

---

## The Mental Model: Database Transactions

Think of the command system as **database transactions** for your graph:

1. **Atomic Operations** — Each command is a discrete unit of work
2. **Rollback Support** — Every `Do()` has a corresponding `Undo()`
3. **Transaction Grouping** — Multiple commands can be grouped into a single undo step
4. **History Stack** — Commands are pushed/popped like a stack

When you add an operator from the Symbol Browser, this seemingly simple action generates multiple commands (create node, create connections) that are grouped so Ctrl+Z undoes everything at once.

---

## Related Systems

- **[Symbol Browser Popup](../graph/01-symbol-browser.md)** — Triggers node creation
- **[MagGraph Undo/Redo](../maggraph/19-undo-redo.md)** — MagGraph's command usage patterns

---

## Where to Start?

Start with [Chapter 1: Symbol Instance Commands](01-symbol-commands.md) to understand how the Symbol Browser creates operators and connections through the command system.

---

## Version

This documentation describes the Commands system as of **January 2026**.

Last updated: 2026-01-08
