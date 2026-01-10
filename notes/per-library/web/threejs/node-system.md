# [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) Node System (TSL)

> What if shader code could write itself?

## Key Insight

> **TSL's core idea:** Represent shaders as composable node graphs instead of strings, so effects can be combined like functions and compiled to any backend automatically.

---

## The Problem: Why Not Just Write WGSL Directly?

Picture this: you want a simple gradient from red to blue across a mesh. In raw WGSL, you would write something like:

```wgsl
struct Uniforms {
    colorA: vec3f,
    colorB: vec3f,
}
@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@fragment
fn main(@location(0) vUv: vec2f) -> @location(0) vec4f {
    let color = mix(uniforms.colorA, uniforms.colorB, vUv.x);
    return vec4f(color, 1.0);
}
```

That is not terrible for a gradient. But now imagine you want to add some animated noise, maybe a fresnel rim effect, perhaps sample a texture and multiply it in. Your shader grows. You start copying code between projects. You want to reuse that nice fresnel function, but now it is tangled with your gradient code.

The deeper problem is that shaders are strings. Strings do not compose. You cannot take two shader effects and combine them the way you combine JavaScript functions. You cannot inspect a shader at runtime to see what uniforms it needs. If you want to target both WebGPU and WebGL, you are writing everything twice.

This is the problem Three Shading Language (TSL) solves: it lets you compose shaders the way you compose programs—as graphs of operations—and compiles them to whatever backend you need.

---

## The Mental Model: Spreadsheet Formulas

Think of TSL like a spreadsheet. In a spreadsheet, you do not write a program that says "first calculate A1, then use that to calculate B2." Instead, you write formulas in cells that reference other cells: `=A1 * 2` or `=SUM(B1:B10)`. The spreadsheet figures out the order of evaluation automatically.

TSL works the same way. When you write:

```javascript
material.colorNode = mix(colorA, colorB, uv().x);
```

You are not writing imperative code that executes top-to-bottom. You are describing a formula: "the color is the mix of colorA and colorB, weighted by the x coordinate of the UV." This formula references other formulas: `uv()` is itself a node that references vertex attributes, `colorA` might reference a uniform.

Just like a spreadsheet:
- Each "cell" (node) declares what it depends on
- The system figures out evaluation order
- Changing one input propagates through all dependent cells
- You can inspect the dependency graph

The difference? When you "run" this spreadsheet, it compiles to WGSL code that executes on the GPU.

---

## How Node Graphs Work

Every TSL expression creates a node in a directed acyclic graph. When you write `mix(colorA, colorB, uv().x)`, you are building:

```
┌─────────────────────────────────────────────────────────────────────┐
│                      TSL User Code                                   │
│  material.colorNode = mix(colorA, colorB, uv().x)                   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Node Graph                                      │
│  MixNode                                                             │
│    ├── colorA: UniformNode (vec3)                                   │
│    ├── colorB: UniformNode (vec3)                                   │
│    └── factor: UVNode().x (float)                                   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   WGSLNodeBuilder                                    │
│  (webgpu/nodes/WGSLNodeBuilder.js - 66KB)                          │
├─────────────────────────────────────────────────────────────────────┤
│  - Traverse node graph                                               │
│  - Generate WGSL code                                                │
│  - Manage uniforms and bindings                                     │
│  - Handle vertex/fragment stages                                    │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      WGSL Output                                     │
│  @fragment                                                           │
│  fn main() -> @location(0) vec4f {                                  │
│      return vec4f(mix(colorA, colorB, vUv.x), 1.0);                 │
│  }                                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

The key insight is that nodes know two things: their output type (is this a `float` or a `vec3`?) and their dependencies (what other nodes do they need?). The `MixNode` knows it produces a color because `colorA` and `colorB` are colors. It knows it needs three inputs. It knows how to generate WGSL code for itself.

---

## Concrete Example: From TSL to WGSL

Let us trace exactly what happens when you write this material:

```javascript
import { uniform, uv, mix, vec3 } from 'three/tsl';
import { Color } from 'three';

const material = new NodeMaterial();

// Define uniforms
const colorA = uniform(new Color(0xff0000));
const colorB = uniform(new Color(0x0000ff));

// Compose shader graph
material.colorNode = mix(colorA, colorB, uv().x);
```

**Step 1: Node Creation**

When you call `uniform(new Color(0xff0000))`, [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)) creates a `UniformNode`. This node stores a reference to your Color object and knows its type is `vec3`. When you call `uv()`, it creates a `UVNode` that references the vertex attribute. The `.x` swizzle creates another node that extracts a single float.

**Step 2: Graph Assembly**

The `mix(colorA, colorB, uv().x)` call creates a `MixNode` with three children: two uniform nodes and a swizzle node. At this point, nothing has been compiled—you have just built a data structure.

**Step 3: Build Trigger**

When the renderer needs to draw an object with this material, it realizes the material has not been compiled yet. It creates a `WGSLNodeBuilder` and hands it the node graph.

**Step 4: Graph Traversal**

The builder starts at `material.colorNode` (the output) and walks backward through the graph. For each node it visits, it:
1. Recursively processes all input nodes first
2. Asks the node for its WGSL code
3. Collects any uniforms, samplers, or varyings the node needs

**Step 5: Code Generation**

As nodes are visited, the builder accumulates:
- Uniform declarations: `colorA: vec3f, colorB: vec3f`
- Varying declarations: `vUv: vec2f`
- The final expression: `mix(uniforms.colorA, uniforms.colorB, input.vUv.x)`

**Step 6: Output**

The final WGSL emerges:

```wgsl
struct Uniforms {
    colorA: vec3f,
    colorB: vec3f,
}
@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) vUv: vec2f,
}

@fragment
fn main(input: VertexOutput) -> @location(0) vec4f {
    let color = mix(uniforms.colorA, uniforms.colorB, input.vUv.x);
    return vec4f(color, 1.0);
}
```

This shader is cached. Next frame, if nothing has changed, the cached shader is reused.

---

## TSL Syntax Reference

Now that you understand what TSL is doing, here is the syntax in detail.

### Imports

```javascript
import {
    // Core
    Fn, uniform, attribute, varying, output,

    // Math
    vec2, vec3, vec4, float, int, mat3, mat4,
    add, sub, mul, div, mix, clamp, step, smoothstep,
    sin, cos, tan, pow, sqrt, abs, sign, floor, ceil, fract,
    min, max, dot, cross, normalize, length, distance, reflect,

    // Textures
    texture, sampler, textureLoad, textureStore,

    // Accessors
    uv, position, normal, tangent, color,
    modelViewMatrix, projectionMatrix, normalMatrix,

    // Flow control
    If, Loop, Break, Continue, Return
} from 'three/tsl';
```

### Value Nodes

```javascript
// Constants (compile-time values, baked into shader)
const f = float(1.5);
const v2 = vec2(0.5, 0.5);
const v3 = vec3(1.0, 0.0, 0.0);
const v4 = vec4(1.0, 0.0, 0.0, 1.0);
const i = int(42);

// Uniforms (runtime values, updatable from JavaScript)
const time = uniform(0.0);
const color = uniform(new Color(0xffffff));
const matrix = uniform(new Matrix4());

// Attributes (per-vertex data from geometry)
const pos = attribute('position', 'vec3');
const norm = attribute('normal', 'vec3');
const texcoord = attribute('uv', 'vec2');

// Varyings (interpolated from vertex to fragment)
const vNormal = varying(transformedNormalWorld);
```

### Accessor Nodes

```javascript
// Built-in accessors
position;          // Vertex position
normal;            // Vertex normal
uv();              // Texture coordinates
color;             // Vertex color
tangent;           // Vertex tangent

// Transform matrices
modelViewMatrix;   // Model * View
projectionMatrix;  // Projection
normalMatrix;      // Normal transform
modelMatrix;       // Model only
viewMatrix;        // View only

// Camera
cameraPosition;    // Camera world position
```

### Math Nodes

```javascript
// Arithmetic
add(a, b);       // a + b
sub(a, b);       // a - b
mul(a, b);       // a * b
div(a, b);       // a / b

// Functions
mix(a, b, t);    // lerp
clamp(x, min, max);
step(edge, x);
smoothstep(edge0, edge1, x);

// Vector math
dot(a, b);
cross(a, b);
normalize(v);
length(v);
distance(a, b);
reflect(I, N);
refract(I, N, eta);
```

### Texture Nodes

```javascript
// Sample texture (filtered)
const tex = texture(textureMap, uv());
const texRGB = tex.rgb;
const texA = tex.a;

// Texture load (integer coords, no filtering)
const pixel = textureLoad(textureMap, ivec2(0, 0), 0);

// Storage texture (compute shaders)
textureStore(storageTexture, ivec2(x, y), colorValue);
```

---

## Custom Functions: The Fn Decorator

What makes TSL powerful is the ability to define reusable shader functions:

```javascript
const myFunction = Fn(([a, b]) => {
    const sum = add(a, b);
    const product = mul(a, b);
    return mix(sum, product, 0.5);
});

// Use in shader
material.colorNode = myFunction(colorA, colorB);
```

This generates:

```wgsl
fn myFunction(a: vec3f, b: vec3f) -> vec3f {
    let sum = a + b;
    let product = a * b;
    return mix(sum, product, 0.5);
}
```

Here is a more realistic example—a Fresnel rim effect:

```javascript
const fresnelEffect = Fn(([normal, viewDir, power]) => {
    const NdotV = dot(normal, viewDir);
    const fresnel = pow(sub(1.0, clamp(NdotV, 0.0, 1.0)), power);
    return fresnel;
});

// Usage
const viewDirection = normalize(sub(cameraPosition, positionWorld));
const fresnel = fresnelEffect(normalWorld, viewDirection, float(5.0));
material.colorNode = mix(baseColor, rimColor, fresnel);
```

---

## Flow Control

### Conditionals

```javascript
const colorNode = If(condition, () => {
    return colorA;
}).ElseIf(otherCondition, () => {
    return colorB;
}).Else(() => {
    return colorC;
});
```

### Loops

```javascript
const result = Loop({ start: int(0), end: int(10), type: 'int' }, ({ i }) => {
    sum.addAssign(someArray.element(i));
});

// Break/Continue
Loop({ start: 0, end: 100 }, ({ i }) => {
    If(condition, () => { Break(); });
    If(skipCondition, () => { Continue(); });
});
```

---

## Material Integration

TSL integrates with [Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js))'s material system through node slots:

### Standard Material Nodes

```javascript
const material = new MeshStandardNodeMaterial();

// Replace standard outputs
material.colorNode = customColor;           // Albedo
material.normalNode = customNormal;         // Normal map
material.roughnessNode = customRoughness;   // Roughness
material.metalnessNode = customMetalness;   // Metalness
material.emissiveNode = customEmissive;     // Emission
material.aoNode = customAO;                 // Ambient occlusion
material.opacityNode = customOpacity;       // Alpha

// Position modification (vertex shader)
material.positionNode = add(position, mul(normal, displacement));
```

### Custom Material

```javascript
const material = new NodeMaterial();

// Full control over vertex shader
material.vertexNode = Fn(() => {
    const worldPos = mul(modelMatrix, vec4(position, 1.0));
    const clipPos = mul(projectionMatrix, mul(viewMatrix, worldPos));
    return clipPos;
})();

// Full control over fragment shader
material.fragmentNode = Fn(() => {
    const col = texture(diffuseMap, uv());
    return vec4(col.rgb, 1.0);
})();
```

---

## The WGSLNodeBuilder

The builder is where graphs become code:

```javascript
class WGSLNodeBuilder {
    build() {
        // 1. Analyze node graph
        this.analyze(material);

        // 2. Generate vertex shader
        this.buildStage('vertex');

        // 3. Generate fragment shader
        this.buildStage('fragment');

        // 4. Collect bindings
        this.buildBindings();

        return {
            vertexShader: this.vertexShader,
            fragmentShader: this.fragmentShader,
            bindings: this.bindings
        };
    }

    buildNode(node) {
        // Recursively generate code for node and dependencies
        if (node.isOperatorNode) {
            const a = this.buildNode(node.aNode);
            const b = this.buildNode(node.bNode);
            return `(${a} ${node.op} ${b})`;
        } else if (node.isUniformNode) {
            return `uniforms.${node.name}`;
        }
        // ... more node types ...
    }
}
```

---

## Edge Cases and Gotchas

### Type Inference Can Fail

TSL infers types from context. If you write `mix(colorA, someFloat, 0.5)`, it will error because you cannot mix a `vec3` with a `float`. Error messages are not always clear.

### Generated Code Is Hard to Debug

When something goes wrong, you are debugging generated code. The error might say "line 47 of fragment shader" but your actual code is `mix(colorA, colorB, uv().x)`.

### Performance Gotcha: Node Creation Cost

Creating nodes has overhead. Do not recreate your entire node graph every frame:

```javascript
// Good: Create once, update uniform
const timeUniform = uniform(0.0);
material.colorNode = sin(timeUniform);
// Later: timeUniform.value = elapsedTime;

// Bad: Creates new nodes every frame
function animate() {
    material.colorNode = sin(uniform(elapsedTime));  // New nodes!
}
```

---

## [wgpu](https://github.com/gfx-rs/wgpu) Considerations

A similar pattern could be implemented in Rust:

```rust
trait ShaderNode {
    fn output_type(&self) -> WgslType;
    fn generate(&self, builder: &mut ShaderBuilder) -> String;
    fn dependencies(&self) -> Vec<&dyn ShaderNode>;
}

struct UniformNode {
    name: String,
    ty: WgslType,
}

struct MixNode {
    a: Box<dyn ShaderNode>,
    b: Box<dyn ShaderNode>,
    factor: Box<dyn ShaderNode>,
}

impl ShaderNode for MixNode {
    fn generate(&self, builder: &mut ShaderBuilder) -> String {
        let a = self.a.generate(builder);
        let b = self.b.generate(builder);
        let factor = self.factor.generate(builder);
        format!("mix({}, {}, {})", a, b, factor)
    }
}

struct ShaderBuilder {
    uniforms: Vec<UniformDeclaration>,
    vertex_code: String,
    fragment_code: String,
}

impl ShaderBuilder {
    fn build(&mut self, material: &NodeMaterial) -> CompiledShader {
        let color_code = material.color_node.generate(self);

        self.fragment_code.push_str(&format!(
            "@fragment\nfn main() -> @location(0) vec4f {{\n    return vec4f({}, 1.0);\n}}\n",
            color_code
        ));

        CompiledShader {
            vertex: self.vertex_code.clone(),
            fragment: self.fragment_code.clone(),
            bindings: self.uniforms.clone(),
        }
    }
}
```

Rust's ownership model helps here: nodes cannot accidentally share mutable state, and the borrow checker ensures you do not modify a graph while traversing it.

---

## Trade-offs

### Benefits

1. **Composability** — Mix and match shader effects like functions
2. **Type Safety** — Node types enforce valid connections
3. **Backend Agnostic** — Same graph compiles to WGSL or GLSL
4. **Live Updates** — Uniforms can be animated without recompilation
5. **Optimization** — Dead code elimination, constant folding at graph level

### Drawbacks

1. **Complexity** — 66KB of code for WGSLNodeBuilder
2. **Debugging** — Generated code harder to debug than handwritten
3. **Compilation Overhead** — Graph traversal adds first-frame latency
4. **Learning Curve** — Different mental model from traditional shaders

---

## Next Steps

- **[Rendering Pipeline](rendering-pipeline.md)** — How the render loop orchestrates everything
- **[WebGPU Backend](webgpu-backend.md)** — The backend that issues GPU commands
- **[Pipeline & Bindings](pipeline-bindings.md)** — How compiled shaders get cached

---

## Sources

- `libraries/threejs/src/renderers/webgpu/nodes/WGSLNodeBuilder.js`
- `libraries/threejs/src/nodes/` (node implementations)
- `libraries/threejs/src/materials/nodes/NodeMaterial.js`
