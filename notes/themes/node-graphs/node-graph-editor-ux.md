# Node Graph Editor UX: Four Instruments

> How cables.gl, vvvv gamma, tixl, and Werkkzeug4 approach user interaction

---

## The Interaction Challenge

A node graph editor must accomplish something deceptively difficult: it must feel immediate. When an artist drags a connection, the wire must follow without hesitation. When they release over a port, the connection must snap into place instantly. When they search for an operator, the right one must appear before they finish typing. Any friction breaks the creative flow.

Yet behind this immediacy lies substantial complexity. The canvas might hold hundreds of nodes, each with dozens of ports, all connected by bezier curves that must update sixty times per second as the user pans and zooms. Hit testing must determine exactly which element lives under the cursor. Type checking must validate connections without blocking the drag. Undo must capture compound operations as single steps.

Think of a node graph editor like a musical instrument. cables.gl is like a synthesizer with knobs everywhere: immediately responsive, with every parameter visible, but potentially overwhelming for newcomers. vvvv gamma is like a modular synthesizer with patch cables: highly configurable regions and explicit routing, rewarding those who master its organizational vocabulary. tixl is like a piano with pedals: the primary interface is clear and focused, but hidden depth lies beneath for those who know to look. Werkkzeug4 is like an organ: cathedral-scale power requiring deliberate setup, built for those who will invest the time to master its capabilities.

Each instrument serves different performers and performances. The synthesizer thrives in improvisation. The modular rewards systematic thinking. The piano excels at both accessibility and virtuosity. The organ commands attention when the composition demands it. Understanding these different approaches illuminates what makes node graph interaction feel good or frustrating.

---

## Graph Canvas Rendering

### The Performance Problem

Imagine a patch with five hundred operators. Each operator is a rectangle with a title, perhaps a dozen ports, and colored connection indicators. The ports themselves are smaller rectangles requiring precise hit testing. Between operators, hundreds of bezier curves snake their way across the canvas, each updating smoothly as nodes move.

Now render all of this sixty times per second. While the user pans. While zooming. While dragging a node that causes fifty connected curves to recalculate simultaneously. The naive approach collapses under this load. Drawing each element with a separate draw call introduces GPU command overhead that accumulates catastrophically. Five hundred rectangles, five hundred curves, five hundred text labels: fifteen hundred draw calls per frame.

The three instruments solve this differently, each reflecting their platform constraints and design philosophy.

### cables.gl: The WebGL Virtuoso

cables.gl—the synthesizer with knobs everywhere—treats the canvas as a GPU-first problem. Instead of drawing elements one by one, it batches everything into instanced draw calls. All operator rectangles share a single draw call. All bezier curves share another. All text shares a third. The GPU handles the multiplication, rendering thousands of elements in three calls.

The `GlPatch` constructor establishes this rendering hierarchy with `GlRectInstancer` for rectangles, `GlSplineDrawer` for bezier curves, and `GlTextWriter` for labels. Notice the pre-allocation: space for a thousand elements reserved upfront, avoiding expensive reallocation as the patch grows. Each visual element becomes a row in a table of attributes. Position, size, color, hover state: all packed into buffers that the GPU consumes in parallel.

The spline drawer handles bezier curves similarly. Rather than drawing each cable individually, it batches control points and renders all curves in a single pass. The spline shader evaluates bezier equations per-pixel, producing smooth curves regardless of zoom level.

The `GlViewBox` manages the viewport transformation, converting between "patch space" (where operators live) and "screen space" (where pixels appear). Panning and zooming become matrix operations applied uniformly to all rendering.

### tixl: The ImGui Methodist

tixl—the piano with hidden pedals—takes a different path, building on ImGui's immediate-mode rendering. The approach emphasizes cached layout and visibility culling rather than GPU instancing.

The `ScalableCanvas` class provides the coordinate transformation layer. Every drawing call transforms positions from canvas space to screen space; every input event inverse-transforms back. The abstraction is simple but essential: operators think in canvas coordinates, never worrying about current zoom or scroll position.

Performance comes from visibility culling. Before drawing any element, MagGraph checks whether it intersects the visible viewport. An operator off-screen costs nothing to draw. This makes tixl scale well with graph size: doubling the operators does not double the rendering cost if most remain outside the viewport.

### vvvv gamma: The Modular Patchbay

vvvv gamma—the modular synthesizer—renders patches using SkiaSharp, a cross-platform 2D graphics library. The canvas emphasizes visual organization through type-colored links, region boundaries, and clear hierarchical structure.

Links between nodes are color-coded by type. Each data type (Float, String, Spread, etc.) has a distinct color, making the flow of different data types visible at a glance. This visual language helps artists trace data flow without inspecting individual connections.

Regions render as bordered rectangles containing their operations. ForEach regions, Cache regions, and If regions have distinct visual treatments, making control flow structure visible. The splicer bars at region boundaries provide clear entry/exit points for iteration.

Pan and zoom follow standard conventions. The canvas supports arbitrary zoom levels, and nodes maintain crisp rendering through SkiaSharp's vector-based drawing.

### Werkkzeug4: The Custom Craftsman

Werkkzeug4—the cathedral organ—predates modern GPU instancing APIs. Its approach relies on OpenGL with implicit matrix transforms and focuses on semantic organization rather than raw batching. The editor prioritizes demoscene workflows: keyboard-driven operator creation, page-based organization, and tight integration with the type system.

The rendering architecture reflects its era. Operators draw with immediate-mode OpenGL calls, but the overall structure emphasizes navigation and organization. The "page" metaphor groups related operators, and the keyboard-driven workflow minimizes mouse travel.

**Trade-off Table**

| Approach | Technology | Performance | Portability |
|----------|------------|-------------|-------------|
| GPU instancing | WebGL 2.0 | Excellent at scale | Browser only |
| SkiaSharp | Cross-platform 2D | Good | Desktop + mobile |
| ImGui batching | Native | Good with culling | Desktop (Win/Mac/Linux) |
| Custom OpenGL | Native | Good | Desktop (Windows-focused) |

---

## Connection Interaction

### The Wiring Problem

Connecting nodes is the fundamental gesture of visual programming. Click an output. Drag across the canvas. Release on an input. A wire appears. This simple interaction hides several challenges.

During the drag, the user needs feedback. A temporary wire must follow the cursor. When hovering over valid targets, some indication must appear. When hovering over invalid targets, the system should discourage the connection. Upon release, validation happens: do the types match? Would this create a cycle? Only if everything checks out does the permanent connection appear.

The three instruments handle this with increasing sophistication.

### cables.gl: Direct Drag

cables.gl—true to its synthesizer nature—implements the most intuitive workflow: click a port, drag, release on another port. The `GlDragLine` class provides visual feedback, updating its endpoint every frame to track the mouse. Type checking happens at release time: if the target port is compatible, the connection succeeds. If not, nothing happens. The approach prioritizes immediacy. Attempt anything; the system sorts it out at the end.

Port colors provide the type feedback. Blue means number. Orange means trigger. Purple means object. When dragging from a blue port, blue ports on other operators become obvious targets. The visual language helps users find compatible connections without explicit validation.

### tixl: State Machine Clarity

tixl implements connection interaction through an explicit state machine with named states for each phase of the workflow. This structure makes the interaction model clear and extensible.

The states cover multiple workflows: clicking an output enters `HoldOutput`, then transitions to `DragConnectionEnd` as you drag toward a destination. Clicking an input enters `HoldInput`, which opens the placeholder browser to search for a source. The "rip and rewire" workflow lets you drag from an existing wire to disconnect and reconnect elsewhere.

Each state has Enter, Update, and Exit hooks:

```csharp
internal static State<GraphUiContext> DragConnectionEnd = new(
    Enter: _ => { },
    Update: context => {
        if (ImGui.IsKeyDown(ImGuiKey.Escape))
        {
            context.StateMachine.SetState(Default, context);
            return;
        }

        var posOnCanvas = context.View.InverseTransformPositionFloat(ImGui.GetMousePos());
        context.PeekAnchorInCanvas = posOnCanvas;

        if (context.StateMachine.StateTime > 0 && ImGui.IsMouseReleased(ImGuiMouseButton.Left))
        {
            if (InputSnapper.TryToReconnect(context))
            {
                context.Layout.FlagStructureAsChanged();
                context.CompleteMacroCommand();
                context.StateMachine.SetState(Default, context);
                return;
            }
            // ... additional logic
        }
    },
    Exit: _ => { }
);
```

This is the piano revealing its hidden pedals. The basic workflow is click-and-drag. But artists who discover wire-ripping gain substantial productivity, much like pianists who master the sustain pedal transform simple melodies into resonant soundscapes.

### vvvv gamma: Splicer-Aware Connections

vvvv gamma adds a unique dimension to connection interaction: the splicer. When dragging a connection into a ForEach or Repeat region, holding Ctrl+Shift creates a splicer entry point rather than a direct connection. The splicer bar appears at the region boundary, indicating that this spread will iterate.

Standard connections validate types using the .NET type system. Type colors provide immediate feedback: a pink Float link won't connect to a blue String input. The visual mismatch is obvious before you release.

Pin configuration adds another layer. Middle-clicking a pin opens a configuration menu where you can:
- Annotate the type explicitly
- Set default values for inputs
- Change visibility (shown, optional, hidden)
- Convert to a pin group for variadic inputs

The accumulator pattern uses a similar boundary-crossing mechanism. Ctrl+click in a region creates an accumulator input/output pair that carries state between iterations.

### Werkkzeug4: Type-Enforced

Werkkzeug4 approaches connections from the type system first. The `.ops` declaration language specifies input types precisely:

```c
operator Wz4Mesh Transform(Wz4Mesh, ?Wz4Skeleton)
```

`Wz4Mesh` is required. `?Wz4Skeleton` is optional. The compiler generates type checking at connection time. Invalid connections fail immediately, not at render time.

This structural approach trades runtime flexibility for reliability. The organ does not let you play wrong notes; the mechanism prevents it. Artists working within the constraints produce correct results.

**Trade-off Table**

| Approach | Feedback Speed | Error Prevention | Flexibility |
|----------|----------------|------------------|-------------|
| Direct drag | Immediate | At release | High |
| Splicer-aware | Immediate | Type-colored | High (with iteration) |
| State machine | Immediate | Throughout | Very high |
| Type-enforced | At definition | At compile | Medium |

---

## Operator Search

### The Discovery Problem

A mature node graph system might have hundreds of operators. How does an artist find the right one? Alphabetical lists fail: who knows whether "motion blur" lives under M or B? Hierarchical menus fail: navigating through categories interrupts creative flow. The search must be smart enough to surface the right operator before the artist finishes typing.

### cables.gl: Scoring Algorithms

cables.gl implements a multi-factor scoring algorithm that combines name matching, abbreviation matching, port compatibility, and usage patterns:

```javascript
// Scoring factors (points)
// VIP Operator: +2 (MainLoop gets a boost)
// Abbreviation Match: +4 to +12 (shorter abbreviations score higher)
// Summary Contains Query: +1
// ShortName Contains Query: +4
// ShortName Starts With Query: +2.5
// First Port Fits Context: +3
// No Compatible Port: -5 to -10
```

The abbreviation system deserves attention. `DrawImage` becomes `di`. `TextureEffects` becomes `te`. Typing "di" while dragging from a texture output ranks `DrawImage` at the top because:
- Abbreviation "di" matches exactly: +12 points
- First input port is texture: +3 points
- Shortness bonus: +1.8 points
- Total: approximately 17 points

Meanwhile, `Divide` scores negative because its first input is number, not texture: +4 (name contains "di") minus 10 (no texture port) equals -6. The texture context made all the difference.

Math shortcuts add another layer. Typing "+5" creates a Sum operator with 5 already set. Typing "*2" creates Multiply with 2. The search becomes a mini command language.

### tixl: Type-Filtered Browsing

tixl's operator browser (internally called "Placeholder") combines search with type filtering:

```csharp
internal static bool HasMatchingOutput(Symbol symbol, Type requiredOutputType)
{
    foreach (var output in symbol.OutputDefinitions)
    {
        if (output.ValueType == requiredOutputType)
            return true;
        if (requiredOutputType.IsAssignableFrom(output.ValueType))
            return true;
    }
    return false;
}
```

When opening the browser from a dragged connection, only operators with matching input types appear. The filter happens before display, not after. A search for "blur" in a texture context shows only texture blur operators.

The browser also supports preset search. Typing "DrawState blur" finds the DrawState operator with a blur-related preset. The search spans both operator names and preset names, acknowledging that artists often remember effects by their visual result rather than technical implementation.

Multiple trigger methods exist:
- Tab key: Opens at mouse position or connected to selection
- Long press on background: Opens at cursor
- Click on output: Opens filtered to compatible types
- Drop on empty space: Opens with connection preview

### vvvv gamma: NodeBrowser with Categories

vvvv gamma's NodeBrowser combines search with hierarchical categorization. Double-click the canvas or press Tab to open the browser. Type to filter; categories collapse and expand based on matches.

The browser distinguishes between node types visually. Primitive nodes (ForEach, Repeat, If) appear in italics. Process nodes (stateful) appear differently from operations (stateless). This helps artists understand what kind of node they're creating.

Type filtering happens automatically when opening from a dragged connection. Starting a link from an output and opening the browser shows only nodes whose inputs accept that type. The .NET type system powers the filtering, including inheritance-aware matching.

Categories organize nodes by function: Animation, Collections, Control, IO, Math, etc. Artists can navigate by typing category names or by clicking the hierarchy. The search supports partial matching: typing "clamp" finds "Clamp" in Math, "ClampInterpolation" in Animation, etc.

### Werkkzeug4: Categorical Palette

Werkkzeug4—staying true to its organ heritage—uses keyboard shortcuts for common operators (the letter 'o' creates a Torus) and a categorical palette for browsing. Just as an organist memorizes stop combinations, demoscene artists memorize operator shortcuts for their frequently-used tools.

The palette organizes operators by type and function. Mesh generators in one section. Mesh modifiers in another. Material operators elsewhere. Navigation is keyboard-driven: arrow keys move selection, Enter creates.

**Trade-off Table**

| Approach | Discovery | Speed | Learning Curve |
|----------|-----------|-------|----------------|
| Scoring | Excellent | Fast | Medium |
| Type-filtered | Good | Fast | Low |
| NodeBrowser | Good | Fast | Low |
| Categorical | Fair | Medium | Low |

---

## Undo/Redo Systems

### The Reversibility Problem

An artist drags a node onto an existing wire. Internally, this requires: break the existing connection, create connection to the new node's input, create connection from the new node's output, update the node position. Four separate changes.

Press Ctrl+Z. What should happen? Four undos would be confusing. The artist performed one action ("insert here") and expects one undo to reverse it completely.

### tixl: MacroCommand Pattern

tixl solves this with explicit command grouping. The `MacroCommand` class wraps multiple commands into a single undo step:

```csharp
public class MacroCommand : ICommand
{
    private readonly List<ICommand> _commands = new();

    public void AddAndExecCommand(ICommand command)
    {
        command.Do();
        _commands.Add(command);
    }

    public void Undo()
    {
        // Undo in reverse order
        for (var i = _commands.Count - 1; i >= 0; i--)
        {
            _commands[i].Undo();
        }
        IsDone = false;
    }
}
```

The reverse-order undo matters. If you add a connection then move the target, undoing must first undo the move, then remove the connection. Order dependencies are handled automatically.

Usage in the connection workflow:

```csharp
// Start a macro for the entire drag operation
var macroCommand = context.StartMacroCommand("Move and Reconnect");

// Track position changes
context.MoveElementsCommand = new ModifyCanvasElementsCommand(...);
macroCommand.AddExecutedCommandForUndo(context.MoveElementsCommand);

// Delete broken connections
macroCommand.AddAndExecCommand(new DeleteConnectionCommand(...));

// Create new connections
macroCommand.AddAndExecCommand(new AddConnectionCommand(...));

// Finalize
context.CompleteMacroCommand();  // One undo step
```

### cables.gl: Implicit Snapshots

cables.gl uses JSON-based state snapshots for undo. When a significant action completes, the patch state serializes to JSON. Undo restores from the previous snapshot.

This approach trades memory for simplicity. No individual command classes needed. No reverse operations to implement. Restore state by deserializing the snapshot.

The trade-off: larger patches consume more memory for undo history. The approach works well for typical patch sizes but may struggle with enormous productions.

### Werkkzeug4: Graph-Level

Werkkzeug4 tracks structural changes at the graph level. The document maintains its own undo stack of graph states. Individual operator parameter changes may bypass undo (controlled by the "instant apply" workflow) while structural changes capture fully.

**Trade-off Table**

| Approach | Granularity | Memory | Implementation |
|----------|-------------|--------|----------------|
| MacroCommand | Fine | Low | Complex |
| JSON snapshots | Coarse | High | Simple |
| Graph-level | Medium | Medium | Medium |

---

## Key Insight for Rust

These four instruments teach complementary lessons for building a Rust-based node graph editor.

**From tixl, adopt the state machine.** Explicit states eliminate the boolean flag nightmares that plague naive implementations. In Rust, this translates to an enum-based state machine:

```rust
enum GraphState {
    Default,
    HoldItem { item_id: NodeId },
    DragItems { dragged: Vec<NodeId>, start_pos: Vec2 },
    DragConnectionEnd { source: OutputId, temp_wire: TempConnection },
    Placeholder { position: Vec2, type_filter: Option<TypeId> },
}

impl GraphState {
    fn update(&mut self, ctx: &mut GraphContext, input: &Input) -> Option<GraphState>;
}
```

**From tixl, adopt MacroCommand.** The command pattern with explicit grouping handles compound operations correctly. Rust's ownership makes the pattern even safer:

```rust
struct MacroCommand {
    name: String,
    commands: Vec<Box<dyn Command>>,
}

impl Command for MacroCommand {
    fn execute(&mut self, doc: &mut Document) -> Result<()>;
    fn undo(&mut self, doc: &mut Document) -> Result<()> {
        for cmd in self.commands.iter_mut().rev() {
            cmd.undo(doc)?;
        }
        Ok(())
    }
}
```

**From cables.gl, adopt GPU instancing.** The `GlRectInstancer` pattern translates directly to wgpu. Operators become rows in instance buffers. A single draw call renders the entire canvas:

```rust
struct NodeInstance {
    position: [f32; 2],
    size: [f32; 2],
    color: [f32; 4],
    hover: f32,
}

// Single draw call for all nodes
render_pass.set_vertex_buffer(0, quad_vertices);
render_pass.set_vertex_buffer(1, node_instances);
render_pass.draw(0..6, 0..node_count);
```

**From cables.gl, adopt multi-factor scoring.** The search algorithm translates with minor adaptation:

```rust
fn score_operator(op: &Operator, query: &str, context: Option<TypeId>) -> f32 {
    let mut score = 0.0;

    if op.abbreviation == query {
        score += 12.0 - query.len() as f32 * 2.0;
    }
    if op.name.to_lowercase().contains(query) {
        score += 4.0;
    }
    if let Some(ctx_type) = context {
        if op.first_input_type() == Some(ctx_type) {
            score += 3.0;
        } else if !op.has_input_type(ctx_type) {
            score -= 10.0;
        }
    }
    score
}
```

**From vvvv gamma, adopt type-colored links.** Visual type feedback through color makes data flow readable at a glance. In Rust, define a color map:

```rust
fn type_color(type_id: TypeId) -> Color {
    match type_id {
        t if t == TypeId::of::<f32>() => Color::PINK,
        t if t == TypeId::of::<String>() => Color::CYAN,
        t if t == TypeId::of::<Vec<_>>() => Color::ORANGE,
        _ => Color::GRAY,
    }
}
```

**From vvvv gamma, adopt region boundaries as visual constructs.** Rendering regions with clear borders makes control flow structure visible. Splicer bars at boundaries communicate iteration entry/exit points.

**From Werkkzeug4, adopt type safety.** Connections should validate at creation time, not render time. Rust's type system can enforce this:

```rust
// Output and input types must match for connection to exist
struct Connection<T: NodeType> {
    source: OutputPort<T>,
    target: InputPort<T>,
}

// Attempting to connect incompatible types fails at compile time
```

The four instruments play different music. A Rust framework can learn their best techniques and compose something new.

---

## Related Documents

- [Node Graph Systems](./node-graph-systems.md) - Execution models and type systems
- [Node Graph Patterns](../../per-demoscene/fr_public/patterns/node-graph-patterns.md) - Six patterns from Werkkzeug4
- [cables.gl Patch Canvas](../../per-framework/cables/editor/glpatch/01-patch-canvas.md) - GPU rendering details
- [Gray Book: NodeBrowser](../../../references/the-gray-book/reference/hde/the_nodebrowser.md) - vvvv gamma operator search
- [Gray Book: Keyboard Shortcuts](../../../references/the-gray-book/reference/hde/keyboard-shortcuts.md) - vvvv gamma interaction patterns
- [tixl MagGraph Architecture](../../per-framework/tixl/editor/maggraph/01-architecture-overview.md) - Four-layer design
- [tixl State Machine](../../per-framework/tixl/editor/maggraph/07-state-machine.md) - Explicit state transitions
