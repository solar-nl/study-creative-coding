# p5.js Architecture

## Module Dependency Graph

```
app.js (entry)
    │
    ├── core/
    │   ├── main.js ─────────────────── p5 constructor
    │   ├── constants.js ────────────── shared constants
    │   ├── environment.js ──────────── window/display management
    │   ├── rendering.js ────────────── createCanvas, background
    │   ├── structure.js ────────────── push/pop, lifecycle
    │   ├── transform.js ────────────── translate, rotate, scale
    │   ├── p5.Renderer.js ──────────── base renderer class
    │   ├── p5.Renderer2D.js ────────── Canvas 2D implementation
    │   ├── p5.Element.js ───────────── DOM wrapper
    │   ├── p5.Graphics.js ──────────── off-screen buffer
    │   └── shape/ ──────────────────── 2d_primitives, curves, vertex
    │
    ├── color/ ───────── p5.Color, color modes, conversions
    ├── events/ ──────── keyboard, mouse, touch handlers
    ├── math/ ────────── p5.Vector, noise, random, calculations
    ├── image/ ───────── p5.Image, filters, pixels
    ├── io/ ──────────── loadJSON, loadImage, p5.Table, p5.XML
    ├── typography/ ──── p5.Font, text rendering
    ├── dom/ ─────────── createDiv, createButton, etc.
    └── webgl/ ───────── p5.RendererGL, shaders, 3D primitives
```

## Core Abstractions

### p5 Class (`core/main.js`)

The central class that:
- Manages sketch lifecycle (preload, setup, draw)
- Holds state (frameCount, mouseX, mouseY, etc.)
- Provides the prototype for all API methods

### Renderer Hierarchy

```
p5.Renderer (base)
    ├── p5.Renderer2D (Canvas 2D API)
    └── p5.RendererGL (WebGL)
```

### p5.Element

Wrapper around DOM elements, provides:
- Event handling (mousePressed, etc.)
- Style manipulation
- Parent/child relationships

## Initialization Flow

```
1. User includes p5.js
2. Script runs, defines p5 class
3. On DOMContentLoaded:
   a. Global mode: create p5 instance, bind to window
   b. Instance mode: user calls new p5(sketch)
4. Instance creation:
   a. Call preload() if defined
   b. Wait for all async loads
   c. Call setup()
   d. Start draw loop via requestAnimationFrame
```

## Extension Architecture

Methods are added to p5.prototype:

```javascript
// In a module file:
p5.prototype.myFunction = function() {
  // implementation
};

// Optional: register for preload
p5.prototype.registerPreloadMethod('loadMyThing', p5.prototype);
```

## Key Files to Read

| Concept | File | Lines |
|---------|------|-------|
| Constructor | `core/main.js` | ~934 |
| Lifecycle | `core/main.js` | Look for `_start`, `_draw` |
| Global mode | `core/main.js` | Look for `_globalInit` |
| 2D rendering | `core/p5.Renderer2D.js` | ~1342 |
| WebGL rendering | `webgl/p5.RendererGL.js` | Large |
| Event system | `events/keyboard.js`, `events/mouse.js` | |

## Questions for Deep Dive

- [ ] How does the async preload system work?
- [ ] How does global mode detect user-defined setup/draw functions?
- [ ] What's the render loop timing strategy?
- [ ] How does p5.Graphics create off-screen buffers?
