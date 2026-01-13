# Cables.gl

> What if GPU graphics were as approachable as connecting boxes with wires?

---

## The Promise: Visual Programming for GPU Graphics

Most creative coders face a dilemma. They want the power of GPU graphics, but the learning curve is brutal. You need to understand shader languages, buffer management, render passes, and a dozen other concepts before you can draw a glowing circle that responds to music.

Cables takes a different approach: what if you could build GPU graphics by connecting boxes? No code required for the basics, but full shader access when you need it.

This is not just "programming for beginners." Cables implements sophisticated patterns that are worth studying even if you never use the tool itself. The question that guides our exploration: *how do you build a visual programming layer on top of a low-level graphics API?*

---

## Why Study Cables?

Cables solves several hard problems that apply to any creative coding framework:

**The Dataflow Problem.** In a node graph, how do you know which nodes to execute and in what order? Cables uses a dual execution model, continuous value propagation plus trigger-based events, that handles both animation (every frame) and discrete events (mouse clicks, MIDI notes) elegantly.

**The State Management Problem.** Rendering often involves nested contexts: you push a transform, render children, pop the transform. Cables uses stack-based state management that makes hierarchical rendering composable. Think of it like nested function calls, but for GPU state.

**The Shader Modularity Problem.** GLSL shaders are notoriously hard to compose. Cables implements a module injection system that lets you build shaders from reusable pieces, something most frameworks struggle with.

**The API Abstraction Problem.** Cables supports both WebGL and WebGPU from the same visual patches. Understanding how they abstract over two very different APIs teaches valuable lessons about graphics abstraction layers.

---

## Quick Reference

| Property | Value |
|----------|-------|
| **Language** | JavaScript |
| **License** | MIT |
| **Repository** | [cables-gl/cables](https://github.com/cables-gl/cables) |
| **Documentation** | [cables.gl/docs](https://cables.gl/docs/) |
| **Operators** | ~1,734 in base library |
| **Graphics APIs** | WebGL 1/2, WebGPU |

---

## The Core Mental Model

Here is how to think about Cables at the highest level:

```
┌─────────────────────────────────────────────────────────────────┐
│                           Patch                                 │
│  ┌─────────┐      ┌─────────┐      ┌─────────┐                 │
│  │   Op    │      │   Op    │      │   Op    │                 │
│  │ (Mouse) │─────▶│ (Scale) │─────▶│ (Circle)│                 │
│  └─────────┘      └─────────┘      └─────────┘                 │
│       │                │                │                       │
│       └────────────────┴────────────────┘                       │
│                        │                                        │
│                   Ports & Links                                 │
│              (data flows through)                               │
└─────────────────────────────────────────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │      CgContext      │
              │  (abstract graphics)│
              └──────────┬──────────┘
                         │
           ┌─────────────┴─────────────┐
           ▼                           ▼
    ┌─────────────┐             ┌─────────────┐
    │ CglContext  │             │ CgpContext  │
    │  (WebGL)    │             │  (WebGPU)   │
    └─────────────┘             └─────────────┘
```

A **Patch** is a container for **Ops** (operators) connected via **Ports** and **Links**. Each op performs a specific function: reading mouse position, transforming coordinates, drawing shapes. Data flows through the connections.

The key insight: Cables does not use [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) or any existing rendering engine. It implements its own `CgContext` abstraction that targets either WebGL (`CglContext`) or WebGPU (`CgpContext`). This is important because it means the visual programming layer is designed around GPU concepts from the ground up, not bolted onto an existing framework.

---

## Execution: Two Flows Working Together

The mental model above shows *what* Cables is made of. But how does data actually move through those connections? The trickiest part of any node graph is figuring out execution order. Cables uses two complementary mechanisms:

**Value-driven flow** propagates data continuously. When a value changes (say, the mouse moves), it flows downstream through connected ports. Ops that depend on that value see the update automatically. This is how parameters animate smoothly.

**Trigger-driven flow** handles events and rendering. A trigger port fires, causing connected ops to execute in sequence. This is how you control *when* things happen: "when the frame starts, clear the screen, then render this, then render that."

Think of it like plumbing and electricity. Values are like water flowing through pipes, always present, always moving. Triggers are like electrical switches, discrete events that cause specific actions.

**A concrete example.** Imagine a patch where mouse position controls a circle's size:

1. The `Mouse` op continuously outputs x and y coordinates (value ports)
2. These flow downstream to a `Scale` op, which updates its transform matrix
3. Meanwhile, the frame begins: a trigger fires from `MainLoop`
4. The trigger flows through a `Clear` op (clears the canvas)
5. Then to the `Circle` op, which draws using the current scale
6. Result: circle size follows the mouse, redrawn 60 times per second

Values and triggers work in tandem: values prepare the state, triggers execute the work.

This dual model maps surprisingly well to how modern graphics APIs work. Value changes are like updating uniform buffers. Triggers are like recording command buffers.

---

## Concepts That Transfer to [wgpu](https://github.com/gfx-rs/wgpu)

The parallels to modern graphics APIs run deeper than just the execution model. If you are building a Rust creative coding framework with [wgpu](https://github.com/gfx-rs/wgpu), here is what Cables teaches:

| Cables Concept | [wgpu](https://github.com/gfx-rs/wgpu) Equivalent | Why It Matters |
|----------------|-----------------|----------------|
| State stack (push/pop transforms) | Transform hierarchy in scene graph | Composable rendering without global state |
| Trigger-based execution | Command buffer recording | Explicit control over render order |
| Shader modules | WGSL module composition | Reusable shader fragments |
| Context abstraction | Backend-agnostic render abstraction | Future-proofing for API changes |
| Port types (value/trigger/object) | Different data channels in a graph | Type-safe connections |

The state stack pattern is particularly valuable. Instead of setting a global "current transform" and hoping you remember to reset it, you push state, do work, pop state. Children cannot corrupt parent state. This is exactly the pattern you want for hierarchical rendering.

---

## What These Notes Cover

With the core concepts in place, let us explore the details. This documentation examines Cables through three lenses:

| Document | Focus |
|----------|-------|
| [architecture.md](architecture.md) | How the system is composed: Patch, Ops, Ports, Links, and the execution model |
| [rendering-pipeline.md](rendering-pipeline.md) | The frame lifecycle, state stacks, and how rendering actually happens |
| [api-design.md](api-design.md) | How operators are defined, shader module injection, and extension points |
| [trigger-system.md](trigger-system.md) | Deep dive into triggers, trigger-pumped iteration, and error handling |

Each document answers the question: "What patterns here could improve a Rust creative coding framework?"

---

## The Bigger Picture

Cables represents a specific point in the design space: maximum accessibility without sacrificing GPU power. Visual artists can build complex real-time graphics without writing code. Programmers can extend it with custom operators and shaders.

Whether or not visual programming appeals to you, the underlying patterns, dataflow execution, stack-based state, shader modularity, are relevant to any creative coding framework. Cables has spent years refining these ideas in production. We can learn from what they got right.
