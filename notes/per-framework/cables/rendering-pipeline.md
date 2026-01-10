# Cables - Rendering Pipeline

> What happens between clicking 'play' and seeing pixels?

## Key Insight

> **Cables rendering's core idea:** Each frame follows a theater pattern - stage setup (push initial state), performance (ops push/pop their changes in nested order), curtain call (safety cleanup) - ensuring state never leaks between frames.

---

## The Problem: Coordinating a Dance of State Changes

Every frame, a visual programming environment faces a tricky challenge: it must run hundreds of interconnected operations, each potentially changing GPU state, while making sure nothing gets lost or corrupted along the way.

Consider what a single frame might involve: setting up a perspective camera, pushing a blur effect, rendering some geometry with a custom shader, applying post-processing, then restoring everything for the next frame. If any operation forgets to restore a setting it changed, the entire render breaks. If state gets popped in the wrong order, chaos ensues.

The naive approach would be to require every operation to carefully manage its own cleanup. But this is fragile. One forgotten `gl.disable()` and suddenly nothing renders correctly.

Cables solves this with a theater analogy: the render loop is a stage manager who sets up the stage before each performance, lets the actors (ops) perform their scenes, then ensures everything is reset for tomorrow's show.

---

## The Mental Model: A Theater Performance

Think of a Cables frame as a theater production in three acts:

```
┌─────────────────────────────────────────────────────────────────┐
│  ACT 1: STAGE SETUP (renderStart)                               │
│  ├─ Push default state onto all stacks                          │
│  ├─ Set up identity matrices (model/view) and projection        │
│  ├─ Load the default shader                                     │
│  └─ Clear all texture slots                                     │
├─────────────────────────────────────────────────────────────────┤
│  ACT 2: THE PERFORMANCE (MainLoop.trigger)                      │
│  └─ Operators perform in sequence, each pushing/popping state   │
│     ├─ Camera op pushes view matrix                             │
│     ├─ Transform op pushes model matrix                         │
│     ├─ Shader op pushes custom shader                           │
│     ├─ Mesh op renders geometry                                 │
│     └─ Each pops what it pushed                                 │
├─────────────────────────────────────────────────────────────────┤
│  ACT 3: CURTAIN CALL (renderEnd)                                │
│  ├─ Pop any remaining state (safety net)                        │
│  └─ Emit "endFrame" event for cleanup                           │
└─────────────────────────────────────────────────────────────────┘
```

The stage manager (`CglRenderLoop`) keeps this show running continuously using `requestAnimationFrame`, and can limit the frame rate or pause entirely when the editor is idle.

---

## Tracing a Frame: From Request to Pixels

Let's follow exactly what happens when a frame renders. Here's how it plays out:

### Stage Setup (renderStart)

```javascript
// 1. Push initial state onto every stack
cgl.pushDepthTest(true);
cgl.pushBlendMode(cgl.BLEND_NONE);
cgl.pushCullFace(false);

// 2. Reset transformation matrices
mat4.identity(cgl.mMatrix);    // Model: no transformation
mat4.identity(cgl.vMatrix);    // View: no camera offset
mat4.perspective(cgl.pMatrix,  // Projection: perspective view
    45, aspectRatio, 0.1, 1000);

// 3. Establish baseline shader
cgl.pushShader(cgl.defaultShader);

// 4. Clear texture slot tracking
cgl.clearAllTextureSlots();
```

Here's the key insight: everything gets *pushed*, not set directly. This creates a restore point that the frame can unwind to later.

### The Performance (Patch Execution)

Now the patch's MainLoop op fires, triggering a cascade through the operator graph:

```
MainLoop.trigger()
    │
    ├─► PerspectiveCamera op
    │   ├─ pushViewMatrix(cameraTransform)
    │   ├─ trigger children
    │   └─ popViewMatrix()
    │
    ├─► Transform op
    │   ├─ pushModelMatrix(rotation)
    │   ├─ trigger children
    │   │   │
    │   │   └─► CustomShader op
    │   │       ├─ pushShader(compiledShader)
    │   │       ├─ trigger children
    │   │       │   │
    │   │       │   └─► Mesh op
    │   │       │       └─ mesh.render(cgl)  ← Actual draw call
    │   │       │
    │   │       └─ popShader()
    │   │
    │   └─ popModelMatrix()
    │
    └─► [continues through graph...]
```

Each operator has one simple job: push its state change, let its children execute, then pop its state. The nesting naturally ensures everything happens in the right order.

### Curtain Call (renderEnd)

```javascript
// Safety net: pop anything left on stacks
while (cgl.depthTestStack.length > 1) cgl.popDepthTest();
while (cgl.blendModeStack.length > 1) cgl.popBlendMode();
// ... other stacks

// Signal frame complete
cgl.emit("endFrame");
```

This catches any ops that forgot to pop their state, preventing corruption from leaking into the next frame.

---

## The State Stack System: Why Push/Pop Works

Now, the obvious way to manage state would be to just set things directly:

```javascript
// Fragile approach
gl.enable(gl.DEPTH_TEST);
// ... render stuff ...
gl.disable(gl.DEPTH_TEST);  // Easy to forget!
```

Cables instead uses stacks for every piece of GPU state:

```javascript
// Stack-based approach
cgl.pushDepthTest(true);
// ... render stuff ...
cgl.popDepthTest();  // Restores previous value, whatever it was
```

The difference seems small, but it matters a lot. With direct setting, you need to know what the previous value was. With stacks, you just pop and the previous state is automatically restored. No guessing, no tracking.

### Available State Stacks

| Stack | Purpose | Blend Modes |
|-------|---------|-------------|
| `pushDepthTest` / `popDepthTest` | Z-buffer testing | - |
| `pushBlendMode` / `popBlendMode` | Transparency blending | NONE, NORMAL, ADD, SUB, MUL |
| `pushCullFace` / `popCullFace` | Back-face culling | - |
| `pushShader` / `popShader` | Active shader program | - |
| `pushFrameBuffer` / `popFrameBuffer` | Render target | - |
| `pushViewPort` / `popViewPort` | Rendering region | - |

### Nested Rendering Example

Here's where stacks really shine. Imagine rendering a scene with a transparent overlay:

```javascript
// Outer op: opaque rendering
cgl.pushBlendMode(cgl.BLEND_NONE);
cgl.pushDepthTest(true);

    // Inner op: transparent particles
    cgl.pushBlendMode(cgl.BLEND_ADD);
    cgl.pushDepthTest(false);  // Particles don't write depth

        renderParticles();

    cgl.popDepthTest();   // Back to true
    cgl.popBlendMode();   // Back to NONE

    renderOpaqueGeometry();

cgl.popDepthTest();
cgl.popBlendMode();
```

Each push/pop pair is independent. The inner ops don't need to know what the outer ops set, they just restore to "whatever was there before."

### wgpu Equivalent

In wgpu, this pattern maps to render pass and pipeline state:

```rust
// Cables' state stacks → wgpu render pass configuration
let render_pass_desc = wgpu::RenderPassDescriptor {
    depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: &depth_view,
        depth_ops: Some(wgpu::Operations {
            load: wgpu::LoadOp::Clear(1.0),
            store: wgpu::StoreOp::Store,
        }),
        // ...
    }),
    // ...
};

// Blend mode → pipeline state
let blend_state = wgpu::BlendState {
    color: wgpu::BlendComponent {
        src_factor: wgpu::BlendFactor::SrcAlpha,  // BLEND_NORMAL
        dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
        operation: wgpu::BlendOperation::Add,
    },
    // ...
};
```

The main difference here is that wgpu uses immutable pipeline objects rather than mutable state. To get the same stack behavior, you'd maintain a stack of pipeline references and bind whichever one is currently on top.

---

## Shader Compilation: The Module System

Cables shaders aren't monolithic GLSL files. Instead, they're templates with injection points, which lets operators tweak shader behavior without rewriting the whole thing.

### Module Injection Points

```glsl
// Base vertex shader template
void main() {
    vec4 pos = vec4(vPosition, 1.0);

    {{MODULE_VERTEX_POSITION}}  // Ops can inject position modifications

    gl_Position = projMatrix * viewMatrix * modelMatrix * pos;
}

// Base fragment shader template
void main() {
    vec4 col = vec4(1.0);

    {{MODULE_COLOR}}  // Ops can inject color modifications

    outColor = col;
}
```

An operator that wants to add vertex displacement doesn't need to copy the entire shader. It just injects code at the `MODULE_VERTEX_POSITION` point:

```javascript
// Displacement op injects this
shader.addModule({
    name: 'displacement',
    vertexPosition: `
        pos.xyz += normal * texture(displacementMap, texCoord).r * strength;
    `
});
```

### The Compilation Pipeline

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Base GLSL   │────►│  Inject      │────►│  Compile &   │
│  Template    │     │  Modules     │     │  Cache       │
└──────────────┘     └──────────────┘     └──────────────┘
                            │
         ┌──────────────────┼──────────────────┐
         ▼                  ▼                  ▼
   Module from         Module from       Module from
   Displacement Op     Color Op          Light Op
```

### Defines for Conditional Features

Beyond injection, shaders use preprocessor defines:

```javascript
if (useNormalMapping) {
    shader.define('HAS_NORMAL_MAP');
}
```

```glsl
#ifdef HAS_NORMAL_MAP
    vec3 normal = texture(normalMap, texCoord).rgb * 2.0 - 1.0;
#else
    vec3 normal = vNormal;
#endif
```

### Material ID Caching

Each unique combination of modules and defines produces a "material ID." Shaders are cached by this ID, so rendering 1000 objects with the same material only compiles once:

```javascript
const materialId = computeHash(modules, defines);
if (shaderCache.has(materialId)) {
    return shaderCache.get(materialId);
}
// Otherwise compile and cache
```

### wgpu Equivalent

In wgpu, this pattern maps to shader preprocessing or naga module manipulation:

```rust
// Option 1: String preprocessing (similar to Cables)
let shader_source = base_shader
    .replace("{{MODULE_VERTEX_POSITION}}", &displacement_code);

let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    source: wgpu::ShaderSource::Wgsl(shader_source.into()),
    // ...
});

// Option 2: Naga module composition (more robust)
// Compose multiple shader modules at the IR level
```

---

## Mesh Rendering: From Geometry to Draw Calls

The final step is getting triangles onto the screen. Cables wraps all the raw WebGL buffer management in a `Mesh` abstraction that handles the details for you.

### The Mesh Wrapper

```javascript
// Geometry defines the data
const geometry = new CGL.Geometry("cube");
geometry.vertices = [...];      // Position data
geometry.vertexNormals = [...]; // Normal data
geometry.texCoords = [...];     // UV data
geometry.verticesIndices = [...]; // Index buffer

// Mesh manages GPU buffers
const mesh = new CGL.Mesh(cgl, geometry);
```

### Attribute Buffer Management

Each vertex attribute gets its own GPU buffer:

```
┌──────────────────────────────────────────────────────┐
│  Mesh                                                │
├──────────────────────────────────────────────────────┤
│  _bufVertices     → Float32Array → GL_ARRAY_BUFFER   │
│  _bufNormals      → Float32Array → GL_ARRAY_BUFFER   │
│  _bufTexCoords    → Float32Array → GL_ARRAY_BUFFER   │
│  _bufIndices      → Uint16/32    → GL_ELEMENT_ARRAY  │
└──────────────────────────────────────────────────────┘
```

The index buffer type is selected based on vertex count:

```javascript
if (geometry.vertices.length / 3 > 65535) {
    // Need 32-bit indices for large meshes
    indexBuffer = new Uint32Array(indices);
} else {
    // 16-bit is more efficient for smaller meshes
    indexBuffer = new Uint16Array(indices);
}
```

### Instanced Rendering

For rendering many copies of the same geometry (particles, grass, crowds), Cables supports instanced rendering:

```javascript
mesh.numInstances = 1000;
mesh.addAttribute('instancePosition', instancePositions, 3);
mesh.addAttribute('instanceColor', instanceColors, 4);
```

```glsl
// In vertex shader
in vec3 instancePosition;
in vec4 instanceColor;

void main() {
    vec3 worldPos = vPosition + instancePosition;
    // ...
}
```

### wgpu Equivalent

```rust
// Vertex buffers
let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
    contents: bytemuck::cast_slice(&vertices),
    usage: wgpu::BufferUsages::VERTEX,
    // ...
});

// Index buffer with automatic type selection
let (index_buffer, index_format) = if vertices.len() > 65535 {
    (create_u32_buffer(&indices), wgpu::IndexFormat::Uint32)
} else {
    (create_u16_buffer(&indices), wgpu::IndexFormat::Uint16)
};

// Instanced rendering
render_pass.draw_indexed(0..index_count, 0, 0..instance_count);
```

---

## Key Patterns for a Rust Framework

### Pattern 1: Stack-Based State Management

```rust
pub struct StateStack<T: Clone> {
    stack: Vec<T>,
}

impl<T: Clone> StateStack<T> {
    pub fn push(&mut self, value: T) -> &T {
        self.stack.push(value);
        self.stack.last().unwrap()
    }

    pub fn pop(&mut self) -> Option<T> {
        if self.stack.len() > 1 {  // Keep base state
            self.stack.pop()
        } else {
            None
        }
    }

    pub fn current(&self) -> &T {
        self.stack.last().unwrap()
    }
}
```

### Pattern 2: Frame Lifecycle Hooks

```rust
pub trait RenderLoop {
    fn render_start(&mut self, context: &mut RenderContext);
    fn render_frame(&mut self, context: &mut RenderContext);
    fn render_end(&mut self, context: &mut RenderContext);
}
```

### Pattern 3: Shader Module Composition

```rust
pub struct ShaderBuilder {
    base: String,
    modules: HashMap<String, String>,
    defines: HashSet<String>,
}

impl ShaderBuilder {
    pub fn inject_module(&mut self, slot: &str, code: &str) {
        self.modules.insert(slot.to_string(), code.to_string());
    }

    pub fn build(&self) -> String {
        let mut result = self.base.clone();
        for (slot, code) in &self.modules {
            result = result.replace(&format!("{{{{{}}}}}", slot), code);
        }
        result
    }
}
```

---

## What's Next

Now that we've walked through the rendering pipeline, here are some natural next areas to explore:

- **Operator Execution Model**: How the trigger propagation system works
- **Texture Management**: The texture slot allocation and caching system
- **Post-Processing**: How multi-pass rendering is handled

---

## Key Files

| File | Purpose |
|------|---------|
| `src/core/cgl/cgl_renderloop.js` | Frame loop orchestration |
| `src/core/cgl/cgl_state.js` | State stack implementations |
| `src/core/cgl/cgl_shader.js` | Shader compilation and module system |
| `src/core/cgl/cgl_mesh.js` | Mesh wrapper and buffer management |
