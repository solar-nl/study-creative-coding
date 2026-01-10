# ControlP5 Study

> GUI library for Processing with 30+ widgets and method-chaining API

---

## Why Study ControlP5?

Creative coding tools need parameter tweaking. Every artist adjusts values — colors, speeds, sizes, thresholds — while exploring their work. ControlP5 has been the standard solution for Processing users since 2006, providing immediate-mode GUI widgets that integrate seamlessly with sketches.

The library offers a mature perspective on GUI design for creative coding contexts. Unlike general-purpose GUI frameworks (Swing, JavaFX), ControlP5 was built specifically for the rapid iteration cycle of creative work: add a slider, tweak values, see results immediately. This specialization led to interesting design decisions worth studying.

For the Rust framework, ControlP5 provides patterns for:
- **Fluent API design** — Method chaining for widget configuration
- **Automatic variable binding** — Controllers that sync with sketch variables by name
- **Organizational primitives** — Tabs, groups, and accordion layouts
- **State persistence** — Save/load controller states as JSON
- **Custom rendering** — Override default widget appearance

---

## Key Areas to Study

- **Controller architecture** — How 30+ widget types share common behavior via inheritance
- **Event system** — Callbacks, automatic variable binding, ControlEvent dispatch
- **Method chaining** — Fluent API pattern for configuration (`.setPosition().setSize().setRange()`)
- **Layout management** — Tabs, Groups, Accordions for organizing many controls
- **State serialization** — JSON-based properties system for saving/loading
- **Rendering pipeline** — How widgets draw themselves, custom renderers

**Source locations:**
- `src/controlP5/` — All controller implementations
- `src/controlP5/Controller.java` — Base class for all widgets
- `src/controlP5/ControlP5.java` — Main entry point and factory
- `src/controlP5/ControlP5Base.java` — Add methods for all controllers
- `examples/` — Extensive examples for each controller type

---

## Repository Structure

```
controlp5/
├── src/controlP5/
│   ├── ControlP5.java          # Main class, factory methods
│   ├── Controller.java         # Base class for all widgets
│   ├── ControllerGroup.java    # Base for Tab, Group, etc.
│   ├── Slider.java             # Individual controllers...
│   ├── Button.java
│   ├── Toggle.java
│   ├── Knob.java
│   ├── Textfield.java
│   ├── ScrollableList.java
│   └── ... (30+ controller types)
├── examples/
│   ├── controllers/            # Per-controller examples
│   ├── extra/                  # Advanced features
│   └── use/                    # Usage patterns
└── resources/
```

---

## Controller Inventory

| Category | Controllers |
|----------|------------|
| **Value Input** | Slider, Knob, Numberbox, Range, Slider2D |
| **Actions** | Button, Bang, Toggle, Icon |
| **Selection** | CheckBox, RadioButton, ScrollableList, ButtonBar |
| **Text** | Textfield, Textarea, Textlabel |
| **Organization** | Tab, Group, Accordion |
| **Visualization** | Chart, Matrix, ColorPicker, ColorWheel |
| **Special** | Canvas, Pointer, Println, FrameRate |

---

## API Pattern: Method Chaining

ControlP5's signature pattern — configure widgets fluently:

```java
cp5.addSlider("volume")
   .setPosition(20, 20)
   .setSize(200, 20)
   .setRange(0, 100)
   .setValue(75)
   .setColorForeground(color(255, 0, 0))
   .setColorActive(color(255, 128, 0));
```

This pattern is worth extracting for the Rust framework's builder APIs.

---

## Comparison with dat.GUI (JavaScript)

| Aspect | ControlP5 | dat.GUI |
|--------|-----------|---------|
| Language | Java | JavaScript |
| Widget count | 30+ | ~10 |
| Layout | Tabs, Groups, free positioning | Single panel, folders |
| Variable binding | By name (reflection) | By object property |
| Customization | Full rendering override | CSS styling |
| State save | JSON properties | localStorage |

---

## Documents to Create

- [ ] `architecture.md` — Class hierarchy, Controller base class patterns
- [ ] `event-system.md` — Callbacks, ControlEvent, automatic binding
- [ ] `api-design.md` — Method chaining, factory pattern, naming conventions
- [ ] `layout-system.md` — Tabs, Groups, Accordions, positioning
- [ ] `state-persistence.md` — Properties system, JSON serialization

---

## Related Studies

- [toxiclibs](../toxiclibs/) — Another major Processing library (geometry/physics)
- [p5.js](../../per-framework/p5js/) — JavaScript port of Processing
- [Processing](../../per-framework/processing/) — The parent framework
