# Three.js Node System (TSL)

> Three Shading Language - Node graph to WGSL compiler

---

## Overview

Three.js uses a node-based shader system called **TSL (Three Shading Language)** for its WebGPU renderer. Instead of writing WGSL directly, you compose shader graphs using JavaScript that compile to WGSL.

---

## Architecture

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
│  • Traverse node graph                                               │
│  • Generate WGSL code                                                │
│  • Manage uniforms and bindings                                     │
│  • Handle vertex/fragment stages                                    │
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

---

## TSL Basics

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

### Simple Example

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

**Generated WGSL:**

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

---

## Node Types

### Value Nodes

```javascript
// Constants
const f = float(1.5);
const v2 = vec2(0.5, 0.5);
const v3 = vec3(1.0, 0.0, 0.0);
const v4 = vec4(1.0, 0.0, 0.0, 1.0);
const i = int(42);

// Uniforms (updated from JavaScript)
const time = uniform(0.0);
const color = uniform(new Color(0xffffff));
const matrix = uniform(new Matrix4());

// Attributes (per-vertex data)
const pos = attribute('position', 'vec3');
const norm = attribute('normal', 'vec3');
const texcoord = attribute('uv', 'vec2');

// Varyings (vertex → fragment)
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
cameraProjectionMatrix;
cameraViewMatrix;
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

// Trigonometry
sin(x); cos(x); tan(x);
asin(x); acos(x); atan(x);
atan2(y, x);

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
// Sample texture
const tex = texture(textureMap, uv());
const texRGB = tex.rgb;
const texA = tex.a;

// Specific sampler
const sampledColor = texture(textureMap, uv(), sampler(linearSampler));

// Texture load (integer coords, no filtering)
const pixel = textureLoad(textureMap, ivec2(0, 0), 0);

// Storage texture (compute)
textureStore(storageTexture, ivec2(x, y), colorValue);
```

---

## Custom Functions

### Fn Decorator

```javascript
const myFunction = Fn(([a, b]) => {
    const sum = add(a, b);
    const product = mul(a, b);
    return mix(sum, product, 0.5);
});

// Use in shader
material.colorNode = myFunction(colorA, colorB);
```

**Generated WGSL:**

```wgsl
fn myFunction(a: vec3f, b: vec3f) -> vec3f {
    let sum = a + b;
    let product = a * b;
    return mix(sum, product, 0.5);
}
```

### Complex Example

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
    // Loop body
    sum.addAssign(someArray.element(i));
});

// Break/Continue
Loop({ start: 0, end: 100 }, ({ i }) => {
    If(condition, () => {
        Break();
    });
    If(skipCondition, () => {
        Continue();
    });
    // ... body ...
});
```

---

## Material Integration

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

## WGSLNodeBuilder

The node builder traverses the node graph and generates WGSL:

### Build Process

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

    buildStage(stage) {
        // Generate uniforms block
        this.uniforms.forEach(uniform => {
            this.addUniform(uniform);
        });

        // Generate varyings
        this.varyings.forEach(varying => {
            this.addVarying(varying);
        });

        // Generate main function
        this.addCode(`@${stage}\nfn main(...) {\n`);

        // Build each output node
        for (const output of this.outputs) {
            const code = this.buildNode(output.node);
            this.addCode(`${output.name} = ${code};\n`);
        }

        this.addCode('}\n');
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

### Code Generation Example

```javascript
// TSL input
material.colorNode = mix(
    texture(diffuseMap, uv()),
    vec3(1.0, 0.0, 0.0),
    time
);

// Generated WGSL (simplified)
struct Uniforms {
    time: f32,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var diffuseMap: texture_2d<f32>;
@group(0) @binding(2) var diffuseMapSampler: sampler;

@fragment
fn main(@location(0) vUv: vec2f) -> @location(0) vec4f {
    let tex_0 = textureSample(diffuseMap, diffuseMapSampler, vUv);
    let color = mix(tex_0.rgb, vec3f(1.0, 0.0, 0.0), uniforms.time);
    return vec4f(color, 1.0);
}
```

---

## wgpu Considerations

### Shader Graph Pattern

A similar pattern could be implemented in Rust:

```rust
// Node trait
trait ShaderNode {
    fn output_type(&self) -> WgslType;
    fn generate(&self, builder: &mut ShaderBuilder) -> String;
    fn dependencies(&self) -> Vec<&dyn ShaderNode>;
}

// Example nodes
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

// Builder
struct ShaderBuilder {
    uniforms: Vec<UniformDeclaration>,
    vertex_code: String,
    fragment_code: String,
}

impl ShaderBuilder {
    fn build(&mut self, material: &NodeMaterial) -> CompiledShader {
        // Traverse graph, generate WGSL
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

### Benefits of Node System

1. **Composability** - Mix and match shader effects
2. **Type Safety** - Node types enforce valid connections
3. **Backend Agnostic** - Same graph compiles to WGSL or GLSL
4. **Live Updates** - Uniforms can be animated without recompilation
5. **Optimization** - Dead code elimination, constant folding

### Drawbacks

1. **Complexity** - Large codebase (66KB for WGSLNodeBuilder)
2. **Debugging** - Generated code harder to debug than handwritten
3. **Performance** - Graph traversal overhead at compile time
4. **Learning Curve** - Different mental model from traditional shaders

---

## Sources

- `libraries/threejs/src/renderers/webgpu/nodes/WGSLNodeBuilder.js`
- `libraries/threejs/src/nodes/` (node implementations)
- `libraries/threejs/src/materials/nodes/NodeMaterial.js`

---

*Previous: [Pipeline & Bindings](pipeline-bindings.md)*
