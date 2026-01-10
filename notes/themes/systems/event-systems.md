# Theme: Event Systems

> Not yet complete. This theme document needs cross-framework analysis.

Cross-cutting analysis of how frameworks handle input and events.

## Concept Overview

Event systems handle:
- Keyboard input
- Mouse/touch input
- Window events (resize, focus)
- Custom events

## Key Questions

- Polling vs callback-based?
- How are events dispatched?
- How is state tracked (keyIsPressed, etc.)?
- How are multiple windows handled?

## Recommendations for Rust Framework

1. **[winit](https://github.com/rust-windowing/winit) integration** — Use for cross-platform events
2. **State tracking** — Provide current state accessors
3. **Callback closures** — Register event handlers
4. **Event enum** — Type-safe event handling
