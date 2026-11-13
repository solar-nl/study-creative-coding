# Per-Instance Attribute Markers: How to Tell the Pipeline Which Is Which

> WGSL has no way to express per-instance vs per-vertex on a `@location` input — that distinction lives entirely on the host side, so any convention is purely a naming or structuring agreement between shader author and pipeline builder.

---

## The WGSL Gap

When you write a vertex shader in WGSL you annotate inputs with `@location(N)`. The GPU spec says nothing about whether location N is stepped per-vertex or per-instance. That decision is made at pipeline creation time, via the `step_mode` field of each `VertexBufferLayout` in wgpu:

```rust
wgpu::VertexBufferLayout {
    array_stride: ...,
    step_mode: wgpu::VertexStepMode::Instance, // <-- purely host-side
    attributes: &[...],
}
```

The [WGSL specification (W3C TR)](https://www.w3.org/TR/WGSL/) defines `@location`, `@binding`, `@group`, `@builtin`, and other attributes, but contains **no `@step`, `@instance`, or equivalent attribute** for controlling buffer stepping. The spec does not even mention "step_mode."

This means that if you reflect a vertex shader with naga and ask "which of these inputs are per-instance?", naga cannot tell you. The shader text carries no such information. You have to supply it from outside.

This is the gap that any reflected-pipeline system — including CME's `CreateRenderPipelineOp` — must bridge.

---

## Marker Convention Survey

Because the gap is a language limitation, the ecosystem has converged on several different workarounds. None is standardized; each is a convention between shader author and host code.

### Separate Input Structs (WGSL Pattern)

The most widespread convention in wgpu examples (notably the [Learn WGPU instancing tutorial](https://sotrh.github.io/learn-wgpu/beginner/tutorial7-instancing/)) is to split vertex shader arguments into two structs: one for per-vertex data, one for per-instance data, and use separate function parameters for each:

```wgsl
struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal:   vec3<f32>,
};

struct InstanceInput {
    @location(5) model_matrix_0: vec4<f32>,
    @location(6) model_matrix_1: vec4<f32>,
    @location(7) model_matrix_2: vec4<f32>,
    @location(8) model_matrix_3: vec4<f32>,
};

@vertex
fn vs_main(vertex: VertexInput, instance: InstanceInput) -> VertexOutput { ... }
```

The host knows that the first function argument's struct maps to a `Vertex`-step buffer, and the second maps to an `Instance`-step buffer. The struct names `VertexInput` / `InstanceInput` are a human hint, not enforced by the language. The host must hardcode the rule "second struct argument = instance step mode."

**Reflectability:** Naga does expose function arguments and their struct types. A reflector can detect that the vertex entry point has two struct arguments and assign step modes positionally (first = Vertex, second = Instance). This is what learn-wgpu implies, though it is fragile if a shader has a single combined struct.

### Location-Range Convention

Assign a stable location boundary: locations 0–N are per-vertex, locations N+1–M are per-instance. The host packs inputs from each range into separate buffers with the matching step mode.

The learn-wgpu tutorial implicitly uses this: per-vertex attributes occupy locations 0–3, per-instance matrix rows occupy locations 5–8. The gap (4 is unused) is a side-effect, not a design principle.

**Reflectability:** A reflector can split `ReflectedVertexInput` by location threshold. The threshold must be chosen at design time and documented as a convention.

### Struct-Member Naming Convention

Name per-instance members with a distinct prefix or suffix. Bevy's ecosystem discussions mention an `I_` prefix convention for per-instance attributes in custom shader pipelines (though Bevy's standard shaders now use `@builtin(instance_index)` + storage buffer lookups instead of direct `@location` per-instance attributes).

Example:

```wgsl
struct VertexInput {
    @location(0) position:   vec3<f32>,  // per-vertex
    @location(1) normal:     vec3<f32>,  // per-vertex
    @location(2) i_color:    vec4<f32>,  // per-instance (I_ prefix)
    @location(3) i_offset_x: f32,        // per-instance
};
```

The host scans member names: any member whose name starts with `i_` (or `I_`) goes into the instance buffer; the rest go into the vertex buffer.

**Reflectability:** Naga reflects member names. The reflector can filter on the prefix. The convention is legible to a human reading the shader and to a machine parsing names.

### Explicit Host-Side Declaration

Skip in-shader markers entirely. The shader author writes a plain `@location` list; a companion data file (JSON/TOML/comment block) or operator input port specifies which locations are per-instance. The pipeline builder reads both.

This is the most explicit and least ambiguous approach, but it requires the shader author to maintain two files and keep them in sync.

**Reflectability:** Trivially reflectable once the companion declaration is parsed. No naming convention needed in the shader itself.

### Custom Non-Standard Attributes (Not Viable in WGSL)

In GLSL/HLSL it is possible (in some toolchains) to attach user-defined attributes to inputs via `[[annotation]]` extensions. WGSL's attribute list is closed — only the attributes defined in the spec are valid. There is no mechanism to add `@step(instance)` as a user-defined attribute. Naga will reject unknown attributes at parse time.

This option is a dead end for WGSL.

---

## What Naga Reflects

Naga's IR exposes vertex entry point arguments via `naga::Function::arguments`, each carrying an optional `naga::Binding::Location { location, .. }`. For struct arguments, you walk `naga::TypeInner::Struct` members and collect their `Binding::Location` bindings.

CME's `reflect.rs` does exactly this in `extract_vertex_inputs()` (lines 431–473). The result is a flat `Vec<ReflectedVertexInput>` sorted by location, with each entry carrying `{ location, name, format }`.

**Naga does not surface step mode.** There is no `step_mode` field anywhere in `naga::FunctionArgument`, `naga::StructMember`, or `naga::Binding`. Naga translates WGSL to target IR; it has no concept of vertex buffer layout, which is a WebGPU API concept, not a shader language concept. The gap is fundamental, not a gap in CME's reflection code.

---

## Tradeoffs

| Convention | Ergonomics | Reflectability | Migration cost | Ambiguity risk |
|---|---|---|---|---|
| **Separate structs** (two fn args) | Good — visually separates concerns | Medium — must trust argument order | Low — existing shaders use one struct arg | Breaks on combined-struct shaders |
| **Location-range boundary** | Low — requires knowing the threshold | Easy — split on a constant | Medium — must re-number existing locations | Invisible to reader; breaks if locations overlap |
| **Name prefix `i_`** | Good — legible in shader source | Easy — scan member names | Low — add prefix to existing per-instance fields | None once prefix is standardized |
| **Explicit host declaration** | Poor — two files to maintain | Trivial | High — every shader needs a companion | None |
| **Custom WGSL attribute** | Best — but impossible | N/A | N/A | N/A |

The name-prefix convention is the best fit for a reflected pipeline: it is legible in the shader, mechanical to implement in a reflector, requires no structural changes to how the entry point is written, and leaves existing per-vertex-only shaders completely unaffected (they have no `i_`-prefixed members, so the reflector produces one `Vertex`-step buffer, same as today).

---

## Recommendation for CME's Reflected Pipeline

**Adopt the `i_` name-prefix convention.** Any `@location` input whose name starts with `i_` (case-insensitive) is treated as per-instance; all others are per-vertex.

### Example WGSL

```wgsl
struct VertexInput {
    // Per-vertex (stepped once per vertex)
    @location(0) position: vec3<f32>,
    @location(1) uv:       vec2<f32>,

    // Per-instance (stepped once per instance, prefix = i_)
    @location(2) i_color:     vec4<f32>,
    @location(3) i_transform: mat4x4<f32>,  // 4 consecutive locations
};

@vertex
fn vs_main(input: VertexInput) -> VertexOutput { ... }
```

The `i_` prefix is purely a naming contract; the GPU sees nothing special. The host reflector enforces it.

### How `build_vertex_buffers` Should Be Extended

In `flux-gpu-operators/src/operators/create_render_pipeline.rs`, replace the current `build_vertex_buffers` (which packs all inputs into one `Vertex`-step buffer) with a version that splits:

```rust
fn build_vertex_buffers(reflected: &ReflectedShader) -> Vec<VertexBufferLayout> {
    if reflected.vertex_inputs.is_empty() {
        return Vec::new();
    }

    let (instance_inputs, vertex_inputs): (Vec<_>, Vec<_>) = reflected
        .vertex_inputs
        .iter()
        .partition(|input| input.name.to_lowercase().starts_with("i_"));

    let mut layouts = Vec::new();

    // Slot 0: per-vertex attributes
    if !vertex_inputs.is_empty() {
        let mut offset: u64 = 0;
        let mut attrs = Vec::new();
        for input in &vertex_inputs {
            let format = reflected_to_vertex_format(&input.format);
            attrs.push(VertexAttribute::new(format, offset, input.location));
            offset += format.size();
        }
        layouts.push(VertexBufferLayout::new_with_step_mode(
            offset,
            attrs,
            wgpu::VertexStepMode::Vertex,
        ));
    }

    // Slot 1: per-instance attributes (only if any i_-prefixed inputs exist)
    if !instance_inputs.is_empty() {
        let mut offset: u64 = 0;
        let mut attrs = Vec::new();
        for input in &instance_inputs {
            let format = reflected_to_vertex_format(&input.format);
            attrs.push(VertexAttribute::new(format, offset, input.location));
            offset += format.size();
        }
        layouts.push(VertexBufferLayout::new_with_step_mode(
            offset,
            attrs,
            wgpu::VertexStepMode::Instance,
        ));
    }

    layouts
}
```

Note: check whether `slr_wgpu::core::VertexBufferLayout` already has a `step_mode` field or a `new_with_step_mode` constructor. If `VertexBufferLayout::new(stride, attrs)` currently hard-codes `Vertex` step mode, that struct needs a `step_mode` field added before this extension is possible.

### What `DrawIndexedOp` Needs

Once the pipeline has two vertex buffer slots, the draw operator must bind two buffers. The operator should gain an `instance_buffer` input port:

- Slot 0 (`vertex_buffer: BufferHandle`) — already present or implied
- Slot 1 (`instance_buffer: BufferHandle`, default `ResourceId::NONE`) — new

When `instance_buffer` is `NONE`, the operator binds only slot 0 and issues a non-instanced draw (`draw_indexed(0..index_count, 0, 0..1)`). When it is set, it binds slot 1 and uses the instance buffer length to drive `draw_indexed(0..index_count, 0, 0..instance_count)`.

This keeps non-instanced shaders working without any change to the shader source.

### How Existing Shaders Stay Unchanged

The partitioning step produces an empty `instance_inputs` list when no member starts with `i_`. In that case, the function emits exactly one `VertexBufferLayout` with `step_mode: Vertex` — identical to today's output. Existing shaders compile and run without modification.

---

## Migration / Coexistence

- **Shaders with no `i_` inputs:** zero changes, one vertex buffer, works today.
- **New instancing shaders:** add `i_` prefix to per-instance fields. `CreateRenderPipelineOp` automatically produces two buffer layouts.
- **Instance count:** carried via `DrawIndexedOp`'s new `instance_buffer` port. When absent, count = 1.
- **Location numbering:** per-vertex and per-instance locations must not overlap. Convention: per-vertex use low locations (0, 1, 2, ...), per-instance use higher locations (e.g., starting at 8). There is no technical reason to reserve a range, but documenting a boundary (e.g., per-instance start at location 8) prevents accidents and makes inspection easy.
- **mat4x4 spanning four locations:** WGSL does not support `mat4x4<f32>` directly as a vertex input; the shader must decompose it into four `vec4<f32>` members with consecutive locations. Each such column member should be named with the `i_` prefix:

  ```wgsl
  @location(8)  i_model_0: vec4<f32>,
  @location(9)  i_model_1: vec4<f32>,
  @location(10) i_model_2: vec4<f32>,
  @location(11) i_model_3: vec4<f32>,
  ```

---

## References

- [wgpu `VertexStepMode` docs](https://docs.rs/wgpu/latest/wgpu/enum.VertexStepMode.html) — `Vertex = 0`, `Instance = 1`; controlled via `VertexBufferLayout::step_mode`
- [W3C WGSL Specification](https://www.w3.org/TR/WGSL/) — confirmed: no step-mode attribute exists in WGSL; `@location` carries no per-instance semantics
- [Learn WGPU: Instancing tutorial](https://sotrh.github.io/learn-wgpu/beginner/tutorial7-instancing/) — canonical example of two-struct convention with `step_mode: Instance` on `InstanceRaw::desc()`
- [Bevy specialized mesh pipeline example](https://bevy.org/examples/shaders/specialized-mesh-pipeline/) — Bevy avoids per-instance `@location` entirely; uses `@builtin(instance_index)` + storage buffer lookup instead
- [Naga crate docs](https://docs.rs/naga/latest/naga/) — naga IR exposes `Binding::Location` on function arguments and struct members; no step_mode field exists anywhere in the IR
- CME source: `flux-gpu-operators/src/reflect.rs` — `extract_vertex_inputs()` reflects `@location` inputs into `Vec<ReflectedVertexInput> { location, name, format }`; no step mode
- CME source: `flux-gpu-operators/src/operators/create_render_pipeline.rs` — `build_vertex_buffers()` (line 212) packs all reflected inputs into one `Vertex`-step `VertexBufferLayout`; this is the function to extend
