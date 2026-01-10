# Babylon.js Node Materials

> Visual shader programming: how node graphs become GPU code

---

## The Problem: Shader Programming is Hard

Writing shaders means juggling two concerns simultaneously: the visual effect you want, and the arcane syntax of GLSL or WGSL. You want a metallic surface with scratches? That's fresnel equations, normal mapping, PBR math — and getting the code to compile on all platforms.

Most 3D artists aren't programmers. Most programmers aren't graphics specialists. How do you let everyone create custom materials?

The answer is visual programming. Instead of writing code, you connect nodes in a graph. Each node represents an operation: add two vectors, sample a texture, compute lighting. The system compiles this graph into shader code automatically.

Babylon's Node Material system has 124 block types, supports both GLSL and WGSL, and powers everything from simple color operations to full PBR materials. Understanding how it works reveals patterns useful for any shader graph system.

---

## The Mental Model: Circuit Board

Think of a Node Material like an electronic circuit on a breadboard.

**Nodes are components.** A resistor, a capacitor, an LED. Each has specific inputs and outputs with defined types. An LED needs voltage in; a resistor modifies current flow.

**Connections are wires.** Electricity flows from outputs to inputs. You can't connect an audio jack to a power socket — types must match.

**The power source is vertex data.** Position, normal, UV coordinates flow from the vertex shader into the circuit.

**The final LED is the output.** Fragment color, emitted light — what appears on screen.

The circuit compiler (Node Material build system) traces wires from power source to LED, generating the minimal code path needed.

---

## System Architecture

The Node Material system consists of several cooperating classes:

```
NodeMaterial
├── Manages the graph
├── Orchestrates compilation
└── Produces Effect (compiled shader)

NodeMaterialBlock (base class)
├── Defines inputs/outputs
├── Generates shader code
└── 124 specialized subclasses

NodeMaterialConnectionPoint
├── Type information
├── Connection state
└── Generated variable names

NodeMaterialBuildState
├── Accumulates shader code
├── Tracks variables and functions
└── Handles vertex→fragment varyings

NodeMaterialBuildStateSharedData
├── Shared across vertex/fragment
├── Prevents duplicate compilation
└── Collects defines and bindings
```

---

## Building a Node Material

Before diving into internals, here's how you use the system:

```typescript
const nodeMaterial = new NodeMaterial("custom");

// Input: vertex position
const positionInput = new InputBlock("position", NodeMaterialBlockTargets.Vertex);
positionInput.setAsAttribute("position");

// Transform by world-view-projection matrix
const worldPosBlock = new TransformBlock("worldPos");
const wvpInput = new InputBlock("worldViewProjection", NodeMaterialBlockTargets.Vertex);
wvpInput.setAsSystemValue(NodeMaterialSystemValues.WorldViewProjection);

positionInput.output.connectTo(worldPosBlock.vector);
wvpInput.output.connectTo(worldPosBlock.transform);

// Output: transformed position
const vertexOutput = new VertexOutputBlock("vertexOutput");
worldPosBlock.output.connectTo(vertexOutput.vector);

// Fragment: simple color
const colorInput = new InputBlock("color");
colorInput.value = new Color4(1, 0.5, 0.2, 1);

const fragmentOutput = new FragmentOutputBlock("fragmentOutput");
colorInput.output.connectTo(fragmentOutput.rgba);

// Compile
nodeMaterial.addOutputNode(vertexOutput);
nodeMaterial.addOutputNode(fragmentOutput);
nodeMaterial.build();
```

This creates a material that transforms vertices and outputs an orange color. Let's trace how `build()` compiles this graph.

---

## The Build Process

Calling `nodeMaterial.build()` (line 813 in `nodeMaterial.ts`) triggers compilation:

### Phase 1: Initialize Build States

```typescript
// nodeMaterial.ts, lines 850-860
this._vertexCompilationState = new NodeMaterialBuildState();
this._vertexCompilationState.target = NodeMaterialBlockTargets.Vertex;

this._fragmentCompilationState = new NodeMaterialBuildState();
this._fragmentCompilationState.target = NodeMaterialBlockTargets.Fragment;
this._fragmentCompilationState._vertexState = this._vertexCompilationState;

// Shared data for both
const sharedData = new NodeMaterialBuildStateSharedData();
this._vertexCompilationState.sharedData = sharedData;
this._fragmentCompilationState.sharedData = sharedData;
```

Two build states are created: one for vertex shader, one for fragment. They share data that spans both (like the build ID that prevents duplicate compilation).

### Phase 2: Register All Blocks

```typescript
// nodeMaterial.ts, lines 872-884
for (const block of connectedBlocks) {
    this._initializeBlock(block);
}
```

Each block registers itself in `sharedData`:
- Input blocks → `sharedData.inputBlocks`
- Texture blocks → `sharedData.textureBlocks`
- Bindable blocks → `sharedData.bindableBlocks`

This lets the material know what uniforms and samplers to declare.

### Phase 3: Build Output Nodes

```typescript
// nodeMaterial.ts, lines 912-928
for (const vertexOutputNode of this._vertexOutputNodes) {
    vertexOutputNode.build(this._vertexCompilationState, vertexNodes);
}

for (const fragmentOutputNode of this._fragmentOutputNodes) {
    fragmentOutputNode.build(this._fragmentCompilationState, fragmentNodes);
}
```

Building starts from output nodes and works backward through the graph.

### Phase 4: Finalize Shaders

```typescript
// nodeMaterial.ts, lines 931-932
this._vertexCompilationState.finalize();
this._fragmentCompilationState.finalize();
```

Each state assembles its accumulated code into a complete shader.

---

## Block Compilation

Each block's `build()` method (in `nodeMaterialBlock.ts`, line 691) follows this pattern:

### Step 1: Process Inputs

```typescript
// nodeMaterialBlock.ts, lines 706-729
for (const input of this._inputs) {
    if (input.connectedPoint) {
        const block = input.connectedPoint.ownerBlock;
        block.build(state, activeBlocks);
    }
}
```

Recursively build all upstream blocks first. This ensures variables are defined before use.

### Step 2: Generate Output Variable Names

```typescript
// nodeMaterialBlock.ts, lines 698-702
for (const output of this._outputs) {
    if (!output.associatedVariableName) {
        output.associatedVariableName = state._getFreeVariableName(output.name);
    }
}
```

Each output gets a unique variable name like `Add_1`, `Multiply_2`, etc.

### Step 3: Call _buildBlock()

This is where subclasses generate their specific code:

```typescript
// addBlock.ts, lines 25-33
protected override _buildBlock(state: NodeMaterialBuildState) {
    super._buildBlock(state);

    const output = this._outputs[0];
    state.compilationString +=
        state._declareOutput(output) +
        ` = ${this.left.associatedVariableName} + ${this.right.associatedVariableName};\n`;

    return this;
}
```

For an AddBlock, this generates:

```glsl
vec3 Add_1 = Position_0 + Offset_2;
```

### Step 4: Process Downstream

After building, the block's outputs may trigger builds of connected blocks.

---

## Context Switching: Vertex to Fragment

The trickiest part of shader graph compilation is handling data that crosses from vertex to fragment shader.

### The Problem

A block might be:
- Vertex-only (like VertexOutput)
- Fragment-only (like FragmentOutput)
- Neutral (like Add, which works in either)
- VertexAndFragment (like some input blocks)

When a fragment block needs data from a vertex block, the system must generate a **varying** to pass data between shader stages.

### The Solution

In `nodeMaterialBlock.ts`, lines 612-640:

```typescript
// When building an input connection
const blockIsFragment = (block.target & NodeMaterialBlockTargets.Fragment) !== 0;
const localBlockIsFragment = (this.target & NodeMaterialBlockTargets.Fragment) !== 0;

if (localBlockIsFragment &&
    ((block.target & block._buildTarget) === 0 ||
     (block.target & input.target) === 0)) {

    // Create a varying to pass data
    state._vertexState.compilationString +=
        `${"v_" + connectedPoint.declarationVariableName} = ${connectedPoint.associatedVariableName};\n`;

    input.associatedVariableName = "v_" + connectedPoint.declarationVariableName;
}
```

If we're in the fragment shader and the input comes from a vertex-stage block, automatically:
1. Declare a varying
2. Assign the value in vertex shader
3. Use the varying in fragment shader

This happens transparently — the block author doesn't need to handle it.

---

## Connection Point Types

Connections are strongly typed. The `NodeMaterialBlockConnectionPointTypes` enum defines:

```typescript
// nodeMaterialBlockConnectionPointTypes.ts
Float      = 0x0001   // Single float
Int        = 0x0002   // Integer
Vector2    = 0x0004   // vec2
Vector3    = 0x0008   // vec3
Vector4    = 0x0010   // vec4
Color3     = 0x0020   // RGB color
Color4     = 0x0040   // RGBA color
Matrix     = 0x0080   // mat4
Object     = 0x0100   // Special object types
AutoDetect = 0x0400   // Type inferred from connection
BasedOnInput = 0x0800 // Output type follows input type
```

Types use bitmasks for compatibility checking:

```typescript
// Can connect vec3 or Color3 to this input
input.acceptedTypes = Vector3 | Color3;  // 0x0008 | 0x0020 = 0x0028
```

---

## Block Targets

Blocks specify where they can run:

```typescript
// nodeMaterialBlockTargets.ts
Vertex           = 1  // Vertex shader only
Fragment         = 2  // Fragment shader only
Neutral          = 4  // Either shader (math ops)
VertexAndFragment = 3  // Both (Vertex | Fragment)
```

The `VertexOutputBlock` is `Vertex` only — it produces `gl_Position`. The `FragmentOutputBlock` is `Fragment` only — it produces final color. An `AddBlock` is `Neutral` — addition works anywhere.

---

## Shader Language Support

Node Materials compile to both GLSL and WGSL.

### GLSL Output

```glsl
precision highp float;

uniform mat4 worldViewProjection;
uniform vec4 color;

attribute vec3 position;

varying vec3 v_position;

void main() {
    vec4 worldPos = worldViewProjection * vec4(position, 1.0);
    gl_Position = worldPos;
    v_position = position;
}
```

### WGSL Output

```wgsl
struct Uniforms {
    worldViewProjection: mat4x4<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) v_position: vec3<f32>,
}

@vertex
fn main(input: VertexInput) -> VertexOutput {
    var output: VertexOutput;
    let worldPos = uniforms.worldViewProjection * vec4<f32>(input.position, 1.0);
    output.position = worldPos;
    output.v_position = input.position;
    return output;
}
```

The build state's `finalize()` method handles syntax differences:
- GLSL: `uniform`, `varying`, `attribute`
- WGSL: structs with decorators, `@group/@binding`

---

## Block Categories

The 124 block types are organized by function:

### Input Blocks
- `InputBlock` — User-facing inputs (uniforms, attributes, constants)
- Source: `Materials/Node/Blocks/Input/`

### Output Blocks
- `VertexOutputBlock` — Produces `gl_Position`
- `FragmentOutputBlock` — Produces final color
- Source: `Materials/Node/Blocks/Vertex/` and `Fragment/`

### Math Blocks
- `AddBlock`, `SubtractBlock`, `MultiplyBlock`, `DivideBlock`
- `LerpBlock`, `ClampBlock`, `SmoothStepBlock`
- `TrigonometryBlock` — sin, cos, tan, etc.
- Source: `Materials/Node/Blocks/`

### Vector Blocks
- `VectorMergerBlock` — Combine floats into vectors
- `VectorSplitterBlock` — Extract components
- `NormalizeBlock`, `CrossBlock`, `DotBlock`

### Texture Blocks
- `TextureBlock` — Sample 2D textures
- `ReflectionTextureBlock` — Cubemap reflections
- `ImageSourceBlock` — Raw texture data
- Source: `Materials/Node/Blocks/Dual/`

### PBR Blocks
- `PBRMetallicRoughnessBlock` — Full PBR implementation
- `ReflectionBlock`, `RefractionBlock`
- `ClearCoatBlock`, `SheenBlock`, `AnisotropyBlock`
- Source: `Materials/Node/Blocks/PBR/`

### Control Flow
- `ConditionalBlock` — if/else logic
- `TeleportInBlock`, `TeleportOutBlock` — Cross-shader communication

---

## The Node Material Editor

The visual editor (`packages/tools/nodeEditor/`) provides:

### Visual Graph Interface
- Drag blocks from palette
- Connect wires between ports
- Real-time preview

### Graph ↔ Material Sync
- `BlockNodeData` wraps `NodeMaterialBlock`
- `ConnectionPointPortData` wraps connection points
- Changes in UI update the underlying graph

### Serialization
- Save/load as JSON
- Share via snippet server
- Export as standalone material

### Live Preview
- See material on a mesh in real-time
- Watch shader code update as you connect nodes

---

## Example: Building a Gradient

Let's trace a simple gradient from top to bottom of a mesh:

**Graph:**
```
[UV Input] → [Split Y] → [Gradient Output]
      ↓           ↓
[Color A]    [Color B] → [Lerp] → [Fragment Output]
```

**Generated Code:**

```glsl
// Fragment shader
varying vec2 v_uv;

uniform vec4 colorA;
uniform vec4 colorB;

void main() {
    float t = v_uv.y;  // From UV split
    vec4 gradient = mix(colorA, colorB, t);  // Lerp
    gl_FragColor = gradient;
}
```

**Block Compilation Trace:**

1. `FragmentOutputBlock.build()` called
2. Needs input → calls `LerpBlock.build()`
3. LerpBlock needs gradient, left, right → calls each
4. `SplitterBlock.build()` extracts UV.y
5. `InputBlock.build()` for UV creates varying
6. `InputBlock.build()` for colors creates uniforms

---

## PBR Example

The `PBRMetallicRoughnessBlock` encapsulates full physically-based rendering:

```typescript
const pbrBlock = new PBRMetallicRoughnessBlock("pbr");

// Connect inputs
worldPositionInput.output.connectTo(pbrBlock.worldPosition);
worldNormalInput.output.connectTo(pbrBlock.worldNormal);
albedoTexture.rgba.connectTo(pbrBlock.baseColor);
metallicTexture.r.connectTo(pbrBlock.metallic);
roughnessTexture.g.connectTo(pbrBlock.roughness);

// Output to fragment
pbrBlock.diffuseOutput.connectTo(fragmentOutput.rgb);
```

This single block generates hundreds of lines of shader code handling:
- Fresnel reflections
- Image-based lighting
- Shadow mapping
- Normal mapping
- Ambient occlusion

The block author encoded PBR theory once; users just connect wires.

---

## wgpu Implementation Considerations

Building a shader graph system for wgpu:

### Type System
Use Rust enums for connection types:

```rust
enum NodeType {
    Float,
    Vec2,
    Vec3,
    Vec4,
    Mat4,
    Texture2D,
    // ...
}

struct ConnectionPoint {
    name: String,
    node_type: NodeType,
    connected_to: Option<OutputRef>,
}
```

### Code Generation
Build WGSL strings:

```rust
trait NodeBlock {
    fn build(&self, state: &mut BuildState) -> Result<(), BuildError>;
    fn outputs(&self) -> &[OutputPoint];
    fn inputs(&self) -> &[InputPoint];
}

impl NodeBlock for AddBlock {
    fn build(&self, state: &mut BuildState) -> Result<(), BuildError> {
        let output = self.outputs[0].variable_name();
        let left = self.inputs[0].connected_variable();
        let right = self.inputs[1].connected_variable();

        state.emit(format!("let {} = {} + {};", output, left, right));
        Ok(())
    }
}
```

### Varying Generation
Track vertex/fragment boundary crossings:

```rust
struct BuildState {
    current_stage: ShaderStage,
    varyings: Vec<VaryingDecl>,

    fn cross_stage(&mut self, from: &OutputPoint) -> String {
        let varying_name = format!("v_{}", from.name);
        self.varyings.push(VaryingDecl {
            name: varying_name.clone(),
            node_type: from.node_type,
        });
        varying_name
    }
}
```

---

## Key Source Files

| Purpose | Path | Key Lines |
|---------|------|-----------|
| Main material class | `Materials/Node/nodeMaterial.ts` | build() at 813 |
| Block base class | `Materials/Node/nodeMaterialBlock.ts` | build() at 691 |
| Connection points | `Materials/Node/nodeMaterialBlockConnectionPoint.ts` | Line 90 |
| Build state | `Materials/Node/nodeMaterialBuildState.ts` | finalize() at 156 |
| Shared data | `Materials/Node/nodeMaterialBuildStateSharedData.ts` | Line 116 |
| Type enums | `Materials/Node/Enums/nodeMaterialBlockConnectionPointTypes.ts` | |
| Target enums | `Materials/Node/Enums/nodeMaterialBlockTargets.ts` | |
| Example: Add | `Materials/Node/Blocks/addBlock.ts` | _buildBlock at 25 |
| Vertex output | `Materials/Node/Blocks/Vertex/vertexOutputBlock.ts` | Line 61 |
| Fragment output | `Materials/Node/Blocks/Fragment/fragmentOutputBlock.ts` | |
| PBR block | `Materials/Node/Blocks/PBR/pbrMetallicRoughnessBlock.ts` | |
| Editor | `tools/nodeEditor/src/` | |

All paths relative to: `packages/dev/core/src/`

---

## Next Steps

With Node Materials understood:

- **[API Design](api-design.md)** — How TypeScript patterns enable this flexibility
- **[WebGPU Engine](webgpu-engine.md)** — How compiled shaders become GPU programs
