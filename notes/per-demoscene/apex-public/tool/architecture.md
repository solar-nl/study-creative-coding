# apEx Tool Architecture

Building a demo is not writing code. At least, not in the traditional sense. When you're constrained to 64 kilobytes for an entire production, every megabyte of editor, every import library, and every debugging feature becomes a liability the moment you hit "compile for release." The challenge isn't just making great visuals. It's designing a pipeline where artists can work comfortably with unlimited resources during authoring, then export to an executable that contains zero traces of that authoring environment.

apEx solves this with a radical architectural split. The tool is a multi-megabyte graphical application built on Bedrock's Whiteboard GUI system and Phoenix's full engine build. Artists drag nodes in texture graphs, arrange scene hierarchies, and scrub through timeline previews in real time. The MinimalPlayer is a stripped-down executable containing only Phoenix's minimal build, just enough code to load binary data and render it. The tool exports projects as compact binary files. The player loads them and runs. Nothing from the authoring environment makes it into the player.

This architecture matters because most creative tools merge authoring and runtime. Processing includes its IDE in every sketch export. Unity bundles the engine with every build. But when you're targeting 64KB compressed, that conflation is death. The tool must provide every convenience. The player must contain only execution logic. This forces a discipline few frameworks achieve: every class, every function, every abstraction asks "is this authoring or runtime?" The answer determines which executable it compiles into.

The problem apEx addresses is demo production ergonomics at demoscene size constraints. How do you give artists a visual editor with live preview, procedural content generation, timeline sequencing, and multi-pass materials while shipping an executable smaller than a high-res screenshot? The solution is treating the tool and player as completely separate applications that happen to share a common binary format and a subset of shared libraries.

Think of apEx like a Digital Audio Workstation for visuals. The DAW (the apEx tool) has tracks, effects, automation curves, and a timeline. You arrange everything visually, adjust parameters with sliders, and hear instant playback. When you export, you don't ship the DAW. You export an audio file. apEx is the same: the tool is the production environment. The MinimalPlayer is the exported artifact. Both understand the same data format, but only the player needs to fit on a floppy disk.

## Overview: Two Applications, One Format

The apEx tool architecture consists of three executables and one shared project format.

**apEx.exe** is the authoring application. It's a complete visual editor built on Whiteboard GUI widgets. Artists create texture operator graphs, build mesh hierarchies, design materials with multi-pass shaders, choreograph scene timelines, and preview everything in real time. This application is megabytes. It includes Assimp for model import, full Phoenix with debug features, procedural content generators, and the entire Whiteboard UI system. Size doesn't matter because artists run it on workstations, not deliver it to audiences.

**MinimalPlayer.exe** is the release player. It contains Phoenix compiled in minimal mode, stripping out all editor-specific features, debug code, and optional subsystems. The player's main loop is brutally simple: load binary project data, initialize DirectX, start music playback, enter render loop. Render frames based on music sync position. Swap buffers. Repeat until music ends or ESC is pressed. This executable compresses to under 64KB.

**Phoenix_Tool/** is a bridge layer between Phoenix runtime and the apEx editor. Phoenix itself is data-driven: it loads scenes, materials, and timelines from binary formats. Phoenix_Tool extends Phoenix classes with editor-specific metadata. `CphxScene` becomes `CphxScene_Tool` with GUI callbacks. `CphxMaterial` becomes `CphxMaterial_Tool` with shader code editing. These tool classes serialize to the same binary format the player expects, but during authoring they carry extra data the player never sees.

**CapexProject** is the in-memory representation of a demo project. It manages collections of texture pages, materials, models, scenes, render targets, and timeline events. The project loads from and saves to XML during development (for human readability and version control). On export, it serializes everything to compact binary data. The MinimalPlayer deserializes this binary directly into Phoenix runtime objects.

## The Problem: Authoring vs. Runtime

Demo tools face a unique constraint. Game engines can ship multi-gigabyte runtimes because games are gigabytes. Video editors can bundle ffmpeg because video files are megabytes. But demoscene intros are 64KB compressed. Every byte counts. You can't afford the luxury of shipping editor code.

Traditional approaches fail here. If you make artists write code (like OpenFrameworks), iteration speed suffers and non-programmers are excluded. If you ship a visual editor with the runtime (like Unity), size explodes. If you use offline rendering (like Blender), you lose real-time feedback. Demoscene tools need visual authoring with instant preview during development, yet produce minimal binaries for release.

The apEx architecture recognizes that authoring and playback have opposite requirements. Authoring needs rich UIs, import capabilities, debugging, undo/redo, and live editing. Playback needs zero overhead: load data, render frames, exit. Merging these creates a lowest-common-denominator mess. Separating them allows each to optimize for its purpose.

The key insight is that demo content is pure data. Texture graphs are operator nodes with parameters. Materials are shader code and state blocks. Scenes are object hierarchies with transformation matrices. Timelines are event arrays with start/end times. None of this requires editor code at runtime. The tool manipulates data. The player executes it. They speak the same binary protocol but live in separate executables.

## Tool vs Player Split

The architecture enforces this separation through conditional compilation and module organization.

### Phoenix: Dual-Build Engine

Phoenix is the rendering engine core. It compiles in two configurations: full build for the tool, minimal build for the player. Preprocessor flags control the difference.

Full builds define `PHX_FULL_BUILD` and enable everything. Scene graph traversal includes debug visualization. Materials support runtime shader recompilation. Memory allocators track leak detection. Destructors clean up resources. Optional features like subscenes, mesh particles, and advanced lighting all compile in. This build links into apEx.exe.

Minimal builds define `PHX_MINIMAL_BUILD` and strip aggressively. Debug features compile to nothing. Destructors disappear (the OS cleans up on exit anyway). Optional subsystems disable via feature flags. The timeline code keeps only event playback, not editing. Spline evaluation stays; spline editing tools vanish. This build links into MinimalPlayer.exe, compressing to a fraction of the full build's size.

The split happens at the class level. Every Phoenix class checks build flags:

```cpp
class CphxMaterial {
  // Runtime data - always present
  CArray<CphxMaterialPass*> Passes;

  #ifdef PHX_FULL_BUILD
  // Tool-only metadata
  CString Name;
  virtual ~CphxMaterial(); // Destructor only in full build
  #endif
};
```

Methods do the same. The material system includes `CreateRenderInstances()` in both builds (needed for rendering). It includes `ValidateShaders()` only in full builds (compilation happens in the tool, not the player).

### Phoenix_Tool: Editor Extensions

Phoenix_Tool wraps Phoenix classes with editor-specific functionality. It exists only in apEx.exe, never in MinimalPlayer.exe.

`CphxMaterial` handles runtime rendering. `CphxMaterial_Tool` adds the material editor GUI:

- Technique management (add/remove techniques, reorder them)
- Shader code editing (syntax highlighting, compilation error display)
- Parameter binding (connect shader parameters to object properties)
- Render target assignment (which textures this material writes to)

The tool class contains a `CphxMaterial` instance internally. When artists edit materials in the GUI, changes update the tool class. When the project exports, the tool class serializes its embedded `CphxMaterial` to binary. The player loads that binary directly into a `CphxMaterial`, never seeing the tool extensions.

This pattern repeats throughout:
- `CphxScene` → `CphxScene_Tool` (object hierarchy editor)
- `CphxTextureOperator` → `CphxTextureOperator_Tool` (texture graph node)
- `CphxTimeline` → `CphxTimeline_Tool` (timeline event editor)
- `CphxModel` → `CphxModel_Tool` (mesh filter graph editor)

The split is clean: runtime classes live in `apEx/Phoenix/`, tool extensions live in `apEx/Phoenix_Tool/`. The player links only Phoenix. The tool links both.

### Whiteboard: GUI System

The tool needs a complete GUI system. Whiteboard provides windows, buttons, text boxes, sliders, tree views, and custom widgets. It's several hundred kilobytes. The player needs exactly zero GUI code.

Whiteboard never compiles into MinimalPlayer. It's a dependency only for apEx.exe. Every tool window (texture graph editor, scene view, material editor, timeline sequencer) derives from `CapexWindow`, which wraps `CWBWindow`. The window system handles layout, input, rendering, and message passing.

The player's entire UI is a fullscreen DirectX swapchain. No widgets. No windows. No menus. Just pixels.

## Editor UI: The CapexRoot and WorkBench System

The apEx tool organizes its interface around workbenches. A workbench is a workspace containing multiple editor windows. Think Photoshop's multi-window layouts or Blender's workspaces.

### CapexRoot: Application Container

`CapexRoot` is the top-level application window. It manages:

- **Workbench tabs** — Artists can create multiple workbenches (e.g., "Textures", "Scenes", "Timeline"). Each tab switches between workbench layouts.
- **Menu system** — File, View, Help menus for project operations and window visibility.
- **Console** — A command-line interface for advanced operations and scripting.
- **Fullscreen preview** — Toggle fullscreen playback to see the demo at release resolution.

The root handles global shortcuts (Ctrl+S for save, F11 for fullscreen preview) and dispatches commands to the active workbench.

### CapexWorkBench: Window Manager

Each workbench (`CapexWorkBench`) contains a collection of tool windows. Artists create windows for specific tasks:

- **TexGenMain** — Texture operator graph editor
- **SceneGraph** — Scene hierarchy tree view
- **MaterialEditor** — Material and shader editing
- **TimelineEditor** — Event timeline sequencer
- **ModelView** — 3D viewport for model preview
- **SceneView** — 3D viewport for scene preview

Windows dock and snap to each other. Drag a window's title bar, and visual indicators show where it can dock (left, right, top, bottom). Release to dock. Windows remember their positions per workbench. Switching workbenches restores window layouts.

The workbench tracks which page is being edited (texture pages are separate graph canvases). It also manages the preview scene for model/material editing, automatically updating the preview when artists change data.

## Node Graph System: Texture Operators

The texture generation system is the most visually distinctive part of apEx. Artists build procedural textures by connecting operator nodes in directed graphs.

### Operator Types

Every texture operator has a type determining what it does:

- **Filters** apply image effects (blur, sharpen, distort, color adjustments)
- **Generators** create patterns (perlin noise, gradients, fractals)
- **Load** imports external images
- **Save** marks textures for export
- **Subroutine** defines reusable sub-graphs
- **SubroutineCall** invokes a subroutine
- **NOP** passes through data unchanged (useful for organizing graphs)

Operators are rectangular boxes on a grid. They have input slots (left side) and output slots (right side). Connections are implicit: when an operator's bounding box overlaps another's, they connect. Right-side outputs feed into left-side inputs. This differs from traditional node editors with explicit wires. apEx optimizes for speed: create an operator, drag it next to another, release. They connect.

### TexGenMain Window

The texture graph editor (`CapexTexGenMainWindow`) is a gridded canvas displaying operators. Artists navigate by:

- **Panning** — Middle-mouse drag to scroll
- **Zooming** — Mouse wheel adjusts grid size (5-17 pixels per grid unit)
- **Creating operators** — Press spacebar to open the operator creation menu, select a filter, drag to position
- **Moving operators** — Left-click-drag selected operators
- **Resizing operators** — Shift-left-click-drag to adjust width/height
- **Copying operators** — Right-click-drag selected operators
- **Deleting operators** — Select, press Delete

Operators color-code by state:
- **Blue** — Normal operator
- **Orange** — Subroutine
- **Gray** — Not yet generated (waiting for dependencies)
- **Yellow** — Currently selected
- **Cyan** — Being previewed in a preview window

The grid snaps operator positions to integer coordinates. This ensures pixel-perfect alignment and makes connections predictable. Operators can't overlap (except when copying, briefly). Releasing an operator onto another deletes it.

### Operator Connections and Data Flow

Texture operators form a directed acyclic graph (DAG). Data flows from generators through filters to saves. The tool automatically determines operator evaluation order by topology sorting.

Each operator specifies input requirements:
- Number of required inputs (0-4)
- Input types (textures, UV coordinates, parameters)

When operators connect spatially, the tool validates compatibility. A blur filter requires one input texture. A blend filter requires two. Connecting incompatible operators shows a red bar at the operator's top, indicating invalid inputs.

Operators also have parameters (filter-specific settings). A blur might have radius, iterations, and type. These appear in the **TexGenParameters** window when an operator is selected. Artists adjust sliders and see results update in real time in the preview window.

### Live Preview and Generation

The **TexGenPreview** window shows an operator's output. Double-click an operator to preview it. The preview window generates the operator's dependency chain on demand:

1. Build dependency graph (which operators feed this one?)
2. Topologically sort operators
3. Evaluate each operator in order, caching results
4. Display final output as a 2D texture

Generation is lazy. Only operators required for the preview generate. Operators cache their results until invalidated (parameter change, input change). This makes iteration fast: tweak a parameter, see instant feedback.

The tool generates textures at authoring resolution (user-configurable, often 512x512 or 1024x1024). The export process regenerates at target resolutions (often 256x256 or 512x512 for size reasons).

## Timeline System: Event Sequencing

Demos are time-based experiences. The timeline system (`CphxTimeline_Tool`) orchestrates what happens when.

### Timeline Events

The timeline is an array of events. Each event has:
- **Type** (RenderScene, Shadertoy, ParticleCalc, CameraShake, etc.)
- **Start frame** (when the event begins)
- **End frame** (when the event ends)
- **Parameters** (scene to render, camera to use, render targets, etc.)

Events overlap. A demo might render a scene (RenderScene), apply a blur (Shadertoy), and shake the camera (CameraShake) simultaneously. The engine evaluates all active events each frame in priority order.

Events can render to textures. A RenderScene event might target a custom render target, not the screen. A later Shadertoy event consumes that texture as input. This enables complex multi-pass effects: render scene to texture, apply bloom, composite with another layer, output to screen.

### TimelineEditor Window

The timeline editor displays events as horizontal bars on a frame-based timeline. The x-axis is time (frames), the y-axis is event type. Artists:

- **Create events** — Right-click timeline, select event type
- **Move events** — Drag event bars left/right (change start time)
- **Resize events** — Drag event bar edges (change duration)
- **Edit event parameters** — Select event, adjust properties in **TimelineEventParameters** window

The timeline syncs with music. Artists import an audio track (OGG, WaveSabre, V2M formats supported). The timeline displays audio waveform in the background. Scrubbing the timeline plays audio from that position. This enables precise sync: place a camera cut on the beat, a scene transition on the drop.

### Spline-Based Animation

Timeline events animate parameters via splines. A RenderScene event might animate camera position, field of view, or material colors. Instead of keyframing parameters directly in the event, artists attach splines.

The **TimelineEventSplines** window shows all spline curves for the selected event. Each curve is a 2D graph (time vs. value). Artists:

- **Add keyframes** — Click to add control points
- **Adjust curves** — Drag control points to shape interpolation
- **Change interpolation mode** — Linear, Catmull-Rom, Bezier

Splines serialize compactly using 16-bit floats. A typical spline (4 control points, Catmull-Rom interpolation) is 10 bytes. This matters when every byte contributes to the 64KB budget.

## Live Preview: Real-Time Rendering

The tool embeds Phoenix for real-time preview. Several windows render 3D content:

### SceneView

The scene viewport (`CapexSceneView`) renders scenes with full lighting, materials, and post-effects. Artists:

- **Navigate** — Mouse drag to orbit camera, scroll to zoom
- **Select objects** — Click objects in the scene hierarchy or viewport
- **Edit transforms** — Drag gizmos to move/rotate/scale objects
- **Preview materials** — Apply materials to objects, see results immediately

The viewport uses the same rendering code as the player. Materials compile and render in real time. Change shader code in the material editor, and the viewport updates. Adjust material parameters, and objects re-render. This tight feedback loop enables rapid iteration.

### ModelView

The model viewport (`CapexModelView`) previews individual models. It's similar to SceneView but focused on mesh editing. Artists:

- **View mesh filters** — See how subdivision, smoothing, and deformation affect models
- **Test materials** — Apply materials to models in isolation
- **Debug geometry** — Visualize normals, UVs, vertex colors

The model system is filter-based, like textures. Artists build models by connecting mesh operators (primitives, modifiers, boolean operations). The ModelView generates and displays the result.

### TimelinePreview

The timeline preview window (`CapexTimelinePreview`) renders the entire demo timeline. It's a fullscreen playback viewport synchronized with audio. Artists press Play to watch the demo from start to finish, scrub to specific moments, or seek to timeline events.

This window uses the exact same rendering path as MinimalPlayer. It evaluates timeline events, animates splines, renders scenes, and applies post-processing. The only difference is it runs in a window instead of fullscreen, and it supports scrubbing and pausing.

## Export Pipeline: Tool to Player

The export process converts in-memory project data to compact binary formats the player loads.

### Binary Serialization Format

The tool saves projects as XML during development (human-readable, version-control-friendly). On export, it serializes to binary.

The binary format is a sequential stream of primitive types:
- **Integers** (8, 16, or 32 bit, signed or unsigned)
- **Floats** (32-bit IEEE 754, or 16-bit half-precision for size)
- **Arrays** (count as integer, followed by elements)
- **Strings** (length as integer, followed by bytes)
- **GUIDs** (128-bit identifiers for cross-referencing objects)

Objects serialize recursively. A scene serializes as:
1. Object count
2. For each object: type tag, GUID, parent GUID, transformation matrix, spline data, type-specific data
3. Spline count
4. For each spline: target property, keyframe count, interpolation mode, control points

No pointers. No padding. No alignment. The format is byte-dense and endianness-agnostic (but assumes little-endian in practice since demos target x86/x64 Windows).

### Resource Dependency Tracking

The export process only includes resources referenced by the timeline. If a texture operator exists but no event uses it, it doesn't export. If a scene exists but no RenderScene event references it, it doesn't export. This "dead code elimination" for resources keeps exported files minimal.

The exporter walks the timeline event graph:
1. Mark all events in the timeline
2. For each event, mark referenced scenes, materials, render targets
3. For each scene, mark objects, models, textures
4. For each model, mark mesh filters, materials
5. For each material, mark techniques, textures
6. For each texture, mark operators in the dependency chain

Unmarked resources don't serialize. The player never sees them.

### Export Targets

The tool can export several binary files:

**Demo Binary** — The full project data (scenes, materials, timeline, textures). MinimalPlayer loads this at startup. It's the largest file (often 20-40KB uncompressed, 8-15KB compressed).

**Precalc Binary** — Pre-generated resources (procedural meshes, textures). Some demos split generation into two phases: precalc creates complex procedural content offline, demo loads it as static data. This trades generation time for file size.

**Minimal Export** — A C++ header file containing the binary data as a char array. This embeds the demo data directly into the MinimalPlayer executable, eliminating file I/O. The entire player becomes a single .exe with embedded data.

### Compression

After binary serialization, the player executable compresses with kkrunchy (a demoscene-specific executable compressor). kkrunchy:

- Unpacks at runtime (adds tiny decompression stub to executable)
- Achieves 50-70% compression on typical demo data
- Optimizes for demo-specific patterns (lots of zeros, repetitive data structures)

The final release process:
1. Export binary data from apEx
2. Compile MinimalPlayer with embedded data
3. Strip debug symbols
4. Run kkrunchy compression
5. Result: 64KB (or less) executable

## MinimalPlayer: Minimal Runtime

The player is brutally simple by design. Its `WinMain()` function:

1. **Load libraries** — LoadLibrary for DirectX, DirectSound (needed for music playback)
2. **Parse embedded data** — Extract strings (group name, title, URLs) and binary blobs (demo data, music data)
3. **Open setup dialog** (optional, `#ifdef`'d out for final releases) — Let users choose resolution, fullscreen vs. windowed
4. **Initialize window** — Create Win32 window, set up DirectX swapchain
5. **Initialize Phoenix** — Call `InitializePhoenix()` to set up rendering subsystems
6. **Load project** — Deserialize demo data into Phoenix objects (`CphxProject::LoadProject()`)
7. **Initialize music** — Decode and start audio playback (V2M, WaveSabre, or OGG)
8. **Main loop**:
   - Poll Windows messages (detect ESC key to exit)
   - Get current music position (`MUSIC_GETSYNC()`)
   - Render frame (`Demo.Render(currentFrame)`)
   - Swap buffers (`SwapChain->Present()`)
9. **Shutdown** — Stop music, release resources, exit

The render loop has zero logic. `Demo.Render()` does everything: evaluate timeline, render events, apply post-processing. The player is a thin shell around Phoenix.

### Minimal Build Configuration

MinimalPlayer defines `PHX_MINIMAL_BUILD` and disables optional Phoenix features. A typical configuration:

```cpp
#define PHX_MINIMAL_BUILD
#undef PHX_OBJ_SUBSCENE         // No subscenes
#undef PHX_HAS_PARTICLE_SORTING // No sorted particles
#undef PHX_EVENT_SHADERTOY      // No shadertoy events (if unused)
#define PHX_FAKE_FARBRAUSCH_INTRO_BUILD // Strip farbrausch compatibility
```

This removes thousands of lines of code. The linker discards unreferenced functions. The result is a tiny executable (10-20KB uncompressed, 4-8KB compressed).

### Conditional Compilation Strategy

Phoenix uses preprocessor macros throughout to control features. Example:

```cpp
#ifdef PHX_OBJ_MODEL
void CphxScene::RenderModels() { /* render logic */ }
#else
void CphxScene::RenderModels() {} // No-op if models disabled
#endif
```

The minimal build defines only features the specific demo uses. No models? `#undef PHX_OBJ_MODEL`. No lights? `#undef PHX_OBJ_LIGHT`. The code literally doesn't compile.

This differs from modern C++ patterns (templates, constexpr) because preprocessor elimination guarantees zero code size cost. Templates might still generate code that the linker includes. Preprocessor-excluded code never reaches the compiler.

## Comparative Analysis: apEx vs. Werkkzeug

apEx doesn't exist in isolation. Comparing it to Farbrausch's Werkkzeug tool (another demoscene production suite) reveals different approaches to the same constraints.

### Similarities

Both split authoring from runtime. Both use node-based operators for procedural content. Both compile to minimal players. Both target 64KB demos. The architectural philosophy is identical: provide a rich editor, export minimal binaries.

### Differences

**Language and libraries**: Werkkzeug is C++ with custom GUI. apEx is C++ with Whiteboard (a more structured GUI system). Werkkzeug has tighter integration with Windows APIs. apEx abstracts DirectX behind CoRE2.

**Operator model**: Werkkzeug operators are monolithic (one operator type handles many filters). apEx operators are granular (one operator type per filter). Werkkzeug's approach is more compact. apEx's approach is more modular.

**Material system**: Werkkzeug materials are multi-pass but shader-centric. apEx materials are technique-based with explicit render layers. apEx gives finer control over render target management.

**Timeline model**: Both use event-based timelines. Werkkzeug's timeline is more integrated with operators (operators can have timelines). apEx's timeline is more centralized (one global timeline, events reference resources).

**Export model**: Werkkzeug generates C++ code from operators, compiles it into the player. apEx generates binary data, the player deserializes it. Werkkzeug's approach enables more compile-time optimization. apEx's approach is faster to iterate (no recompile).

### Tradeoffs

Werkkzeug's code-generation approach produces smaller executables (more aggressive inlining, constant folding). apEx's data-driven approach enables faster iteration (edit-save-run, no compile step). For artists, apEx is more accessible. For size-critical productions, Werkkzeug might win. Both are valid for different priorities.

## Key Abstractions

Several patterns recur throughout the apEx tool architecture.

### Tool Class Wrapper Pattern

Every Phoenix runtime class has a `_Tool` counterpart:

```cpp
// Runtime class (in Phoenix)
class CphxMaterial {
  CArray<CphxMaterialPass*> Passes;
  void Render(/* ... */);
};

// Tool class (in Phoenix_Tool)
class CphxMaterial_Tool {
  CphxMaterial Material; // Embedded runtime class
  CString Name;          // Editor metadata
  void EditShader();     // Editor-only methods
  void ExportBinary(/* ... */);
};
```

The tool class contains the runtime class, adds editor features, and serializes the runtime data on export. This keeps runtime classes clean (no editor pollution) while giving tools rich metadata.

### GUID-Based Cross-Referencing

Projects use GUIDs (128-bit identifiers) to reference objects. A scene references a material by GUID. A timeline event references a scene by GUID. On export, GUIDs map to compact integer IDs. On load, the player rebuilds GUID→object mappings.

GUIDs solve the serialization problem. Pointers are memory-address-specific. GUIDs are stable across save/load cycles. The tool can copy/paste objects, merge projects, or refactor hierarchies without breaking references.

### Live Preview Integration

Every editor window that modifies data triggers regeneration of dependent previews:

```cpp
void MaterialEditor::OnParameterChanged() {
  Material->InvalidateCache();
  Workbench->GetSceneView()->RequestRedraw();
}
```

The workbench tracks which windows display which data. Changes propagate automatically. Artists see instant feedback without manual refresh.

### Conditional Compilation for Size

The tool uses `#ifdef` extensively:

```cpp
#ifdef PHX_FULL_BUILD
void DebugDrawBoundingBox() { /* visualization */ }
#else
void DebugDrawBoundingBox() {} // No-op in minimal build
#endif
```

This is old-school C++ but effective. Modern approaches (constexpr, templates) don't guarantee zero code size. Preprocessor conditionals do. When size matters more than elegance, pragmatism wins.

## Implications for Rust Frameworks

The apEx architecture offers several lessons for Rust-based creative coding tool design.

### Adopt: Clean Authoring/Runtime Separation

The tool/player split is brilliant. Authoring environments can be megabytes, use external libraries, include debugging features, and provide rich GUIs. Runtime players compile only execution logic. Both share a binary format but differ radically in code.

A Rust framework could adopt this pattern:
- **Studio application** — Full-featured editor with egui/iced UI, live coding, visual scripting, debugging
- **Player builds** — Minimal WASM or native executables with zero editor code
- **Shared data format** — Binary serialization format both understand

The key is designing libraries with this split in mind from the start. Core types (vectors, matrices, colors) belong in both. Resource management and rendering belong in both. But GUI, importers, and editors belong only in the studio.

### Adopt: Node-Based Procedural Content

The texture operator graph is exceptionally productive. Artists build complex textures by combining simple filters. The same pattern applies to meshes, animations, and effects.

A Rust framework should embrace node graphs:
- Texture nodes (generators, filters, combiners)
- Mesh nodes (primitives, modifiers, boolean operations)
- Material nodes (shader stages, blend modes, render targets)
- Timeline nodes (events, animations, transitions)

Rust's type system enables compile-time node validation. Node input/output types check at compile time. Invalid connections don't compile. This is safer than apEx's runtime checks.

### Adopt: Timeline as First-Class System

Demos are time-based. The timeline isn't an afterthought; it's the core orchestration mechanism. Events have start/end times. Splines animate parameters. Everything derives from music sync.

A Rust framework should make time explicit:
- `Timeline` trait with `evaluate(t: f32)` method
- `Event` trait for renderable timeline segments
- `Spline<T>` generic for animating any type
- `MusicSync` integration for beat-based animation

This pattern works beyond demos. Games, interactive installations, and generative art all benefit from explicit time modeling.

### Adopt: Live Preview with Shared Rendering

The tool previews using the same rendering code as the player. This eliminates "works in editor, breaks in release" bugs. Materials compile once. Scenes render identically. Post-processing applies the same shaders.

Rust frameworks should avoid separate "preview renderer" and "release renderer." Use the same wgpu pipelines in both. The studio runs them in a window. The player runs them fullscreen. But the GPU commands are identical.

### Modify: Avoid Preprocessor-Heavy Modularity

apEx uses `#ifdef` throughout for feature flags. This works but creates exponential configuration space. Enabling feature A might require enabling features B and C. Tracking dependencies is manual and error-prone.

Rust's Cargo features are superior:
- Additive and composable
- Explicit dependencies (`feature = "particles" requires "physics"`)
- Compiler type-checks all configurations

Use feature flags for optional subsystems:
- `default = ["core-rendering"]`
- `particles = ["dep:particle-lib"]`
- `advanced-lighting = ["core-rendering"]`

The compiler ensures valid feature combinations. Users opt into subsystems without manual flag management.

### Modify: Use Type-Safe Handles Instead of GUIDs

apEx uses 128-bit GUIDs for object references. These serialize easily but provide no type safety. A GUID might reference a texture, a material, or a scene. The code can't tell until runtime.

Rust's type system enables better patterns:
- Generational arenas with typed handles (`Handle<Material>`, `Handle<Scene>`)
- Handles serialize as (index, generation) tuples (8-16 bytes, smaller than GUIDs)
- Dereferencing a handle type-checks: `Handle<Material>` dereferences to `&Material`

This catches errors at compile time: passing a `Handle<Scene>` where `Handle<Material>` is expected fails to compile. GUIDs defer this to runtime.

### Modify: Modern Spline Interpolation

apEx splines use 16-bit floats with Catmull-Rom or Bezier interpolation. This is compact but limited. Modern animation systems support ease-in/ease-out curves, bounce effects, and perceptually uniform motion.

A Rust framework should provide:
- **Compact storage** — Delta-encoding for control points (values rarely jump hugely frame-to-frame)
- **Rich interpolation** — Linear, cubic, ease-in-out, bounce, elastic modes
- **Perceptual color spaces** — Interpolate colors in Oklab, not RGB (avoids muddy midpoints)

The storage cost is identical (4 floats per keyframe) but the quality improvement is dramatic.

### Avoid: Manual Memory Management in Tools

apEx uses raw pointers and manual memory management throughout. This works in C++ with careful discipline but would be unsafe in Rust. Don't fight the borrow checker.

Rust patterns:
- Store objects in arenas, reference by handles
- Use `Rc<RefCell<T>>` for shared mutable ownership (though sparingly)
- Prefer message-passing (channels) over shared state where possible

The borrow checker is not an obstacle. It's a design constraint that pushes toward safer architectures.

## References

- `demoscene/apex-public/apEx/apEx/TexGenMain.cpp` — Texture graph editor UI and operator creation
- `demoscene/apex-public/apEx/apEx/apExRoot.h` — Main application window managing workbenches
- `demoscene/apex-public/apEx/apEx/WorkBench.h` — Workbench system for managing editor windows
- `demoscene/apex-public/apEx/Phoenix_Tool/apxProject.h` — In-memory project representation with resource management
- `demoscene/apex-public/apEx/MinimalPlayer/MinimalPlayer.cpp` — Minimal player main loop and initialization
- `demoscene/apex-public/apEx/Phoenix/Timeline.h` — Timeline event system
- `demoscene/apex-public/apEx/Phoenix/Material.h` — Material and technique system
- `demoscene/apex-public/Bedrock/Whiteboard/Application.h` — GUI application framework
- `notes/per-demoscene/apex-public/architecture.md` — Overall apEx architecture overview
