# Theme: Shader Abstractions

> Not yet complete. This theme document needs cross-framework analysis.

Cross-cutting analysis of how frameworks wrap shader programming.

## Concept Overview

Shader abstractions include:
- High-level material systems
- Shader compilation/loading
- Uniform management
- Pre-built shaders vs custom

## Approaches

| Approach | Examples | Tradeoffs |
|----------|----------|-----------|
| Ahead-of-time compilation | Filament (matc), wgpu (naga) | Better optimization, longer builds, less flexibility |
| Runtime compilation | three.js (TSL node system) | More flexible, runtime overhead, limited optimization |
| String templates | Traditional game engines | Simple but error-prone, hard to optimize |
| Domain-specific language | Filament (.mat files) | Type-safe, optimizable, requires learning DSL |

## tixl — Template-Based Shader Generation

tixl uses a **runtime comment-hook injection** system for composing shader code from modular pieces. This is particularly visible in its particle force system, where 5 of 16 forces use template placeholders to accept runtime-composed SDF and vector field functions.

### Placeholder System

HLSL template files contain comment-delimited hooks that are replaced at runtime:

```hlsl
// Force shader template (e.g., TurbulanceForce.hlsl)
cbuffer Params : register(b1) {
    /*{FLOAT_PARAMS}*/    // → float Frequency; float Phase; ...
};

/*{GLOBALS}*/             // → global variable declarations

/*{FIELD_FUNCTIONS}*/     // → SDF function implementations

float4 GetField(float4 p) {
    float4 f = 1;
    /*{FIELD_CALL}*/      // → f = mySDFFunction(p);
    return f;
}

/*{RESOURCES(t0)}*/       // → StructuredBuffer<T> Name : register(t0);
```

### Code Generation Pipeline

The `GenerateShaderGraphCode.cs` operator orchestrates injection:

```csharp
// Operators/Lib/Symbols/field/render/_/GenerateShaderGraphCode.cs:135-141
private string GenerateShaderCode(string templateCode)
{
    AssembleAndInjectParameters(ref templateCode);  // /*{FLOAT_PARAMS}*/
    AssembleAndInjectCode(ref templateCode);         // /*{GLOBALS}*/, /*{FIELD_FUNCTIONS}*/, /*{FIELD_CALL}*/
    InjectResourcesCode(ref templateCode);           // /*{RESOURCES(t0)}*/
    return templateCode;
}
```

Key design decisions:
- **When**: At runtime, when the shader graph structure changes (detected via `StructureHash`)
- **How**: String replacement — `code.Replace(hookString, generatedCode)`
- **Compilation**: Modified HLSL is compiled via D3DCompiler at runtime
- **Caching**: Only recompiles when structure changes; parameter-only changes skip recompilation

### Advantages and Tradeoffs

| Advantage | Tradeoff |
|-----------|----------|
| Fully composable — any SDF/field can plug into any force | Runtime compilation latency on structural changes |
| No shader permutation explosion | String manipulation is fragile (no type checking at composition time) |
| Parameters extracted automatically from graph nodes | Debug info maps to generated code, not template source |
| Hot-reloadable — template file changes trigger recompilation | Cannot optimize across composition boundaries |

### Comparison with Other Approaches

| Framework | Approach | Composition Model |
|-----------|----------|-------------------|
| **tixl** | Comment-hook string replacement | Runtime HLSL → D3DCompiler |
| **Filament** | `.mat` DSL compiled by `matc` | Ahead-of-time, material-level |
| **three.js** | TSL node system (shader AST) | Runtime AST → GLSL/WGSL |
| **wgpu/naga** | WGSL/SPIR-V with module linking | Ahead-of-time, naga IR |
| **Unity** | Shader Graph → HLSL codegen | Editor-time, visual graph |

tixl's approach is closest to **Unity Shader Graph** in concept but operates at a lower level — injecting raw HLSL code rather than generating from an abstract graph representation. The comment-hook pattern is simpler to implement but offers less opportunity for optimization compared to AST-based approaches.

### Implications for Rust/wgpu

A Rust framework could adopt several strategies inspired by tixl's approach:
1. **Template strings with `format!()` injection** — Direct Rust equivalent, fast to implement
2. **naga IR composition** — Type-safe, optimizable, but more complex to implement
3. **WGSL module system** — Future WGSL spec may support `use`/`import` directives
4. **Hybrid**: Template injection for rapid prototyping, naga composition for production shaders

## Key Questions

- How are shaders loaded/compiled?
- How are uniforms set?
- What abstraction level is exposed?
- How is GLSL/WGSL managed?

## Recommendations for Rust Framework

1. **Pre-built shaders** — Common effects out of the box
2. **Custom shader support** — Allow WGSL/SPIR-V
3. **Uniform helpers** — Type-safe uniform setting
4. **Hot reload** — Development workflow consideration
5. **Template injection** — tixl demonstrates that comment-hook string replacement is a pragmatic, effective approach for runtime shader composition in creative coding tools, where flexibility matters more than compile-time optimization
