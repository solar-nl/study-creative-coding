# Linearly Transformed Cosines (LTC)

> Reference implementation for real-time area light shading using linearly transformed cosines.

## Quick Facts

| Property | Value |
|----------|-------|
| **Type** | Shading/lighting library (reference implementation) |
| **Repository** | [selfshadow/ltc_code](https://github.com/selfshadow/ltc_code) |
| **License** | MIT |
| **Primary Language** | C/C++ (fit), GLSL/JavaScript (WebGL demos) |
| **Key Authors** | Eric Heitz, Jonathan Dupuy, Stephen Hill, David Neubelt |
| **Paper** | [Real-Time Polygonal-Light Shading with Linearly Transformed Cosines (SIGGRAPH 2016)](https://eheitzresearch.wordpress.com/415-2/) |

## Why Study This Library

LTC solves one of the fundamental challenges in real-time rendering: **physically accurate area light shading at interactive frame rates**. Traditional real-time graphics use point/directional lights because they're cheap to compute, but area lights (quad lights, line lights, disk lights) produce much more realistic and artistically controllable lighting.

The problem is that area lights require integrating the BRDF (Bidirectional Reflectance Distribution Function) over the solid angle of the light source, which is computationally expensive. LTC provides an elegant mathematical solution: it transforms the area light into a simpler space where the integral has a closed-form solution, then transforms the result back.

This is directly relevant to creative coding frameworks for several reasons:

### 1. Production-Proven Technique

LTC has been adopted by major game engines and production renderers:
- **Frostbite Engine** (EA DICE) - Used in Battlefield, FIFA, Star Wars games
- **Unity** - Implemented for real-time area lights
- **Unreal Engine** - Area light support in path tracer
- **Arnold Renderer** - Used for area light sampling

### 2. Performance vs Quality Trade-off

LTC achieves near-photorealistic area lighting at ~2-3ms per frame (for multiple lights), making it viable for interactive applications. This is orders of magnitude faster than Monte Carlo integration while maintaining visual quality.

### 3. Lookup Table Architecture

The technique relies on pre-computed lookup tables (LUTs) that encode BRDF transformation matrices. This pattern of "bake expensive math into textures" is widely applicable in real-time graphics and is a key optimization strategy for creative coding tools targeting 60fps.

### 4. Flexible Light Shapes

The original 2016 paper covers polygonal lights (quads), but subsequent work extended LTC to:
- **Line lights** (2017) - Tube lights, neon effects
- **Disk lights** (2017) - Circular area lights
- **Arbitrary polygons** - Any convex polygon works

This flexibility makes LTC a general solution for area lighting rather than a single-purpose technique.

## Core Concept

LTC transforms the area light integration problem into a simpler domain:

```
Original Problem (expensive):
  Integrate BRDF over light polygon → Monte Carlo or analytic (complex)

LTC Solution (fast):
  1. Find matrix M that transforms BRDF into cosine lobe
  2. Transform light polygon by M^-1
  3. Integrate cosine over transformed polygon (closed form!)
  4. Apply Jacobian and amplitude term
```

The key insight is that integrating a **cosine lobe** over a polygon has a known closed-form solution (Arvo 1995), but integrating a GGX or Beckmann BRDF does not. LTC finds the transformation matrix that makes the BRDF look like a cosine lobe.

## Repository Structure

```
ltc_code/
├── fit/                    # LUT generation (C++)
│   ├── fitLTC.cpp         # Main fitting program
│   ├── LTC.h              # Core LTC math
│   ├── brdf_ggx.h         # GGX BRDF implementation
│   ├── brdf_beckmann.h    # Beckmann BRDF
│   ├── brdf_disneyDiffuse.h # Disney diffuse BRDF
│   ├── nelder_mead.h      # Optimization algorithm
│   └── results/ltc.h      # Pre-computed LUT data
├── webgl/                 # Interactive demos
│   ├── ltc_quad.html      # Quad light demo
│   ├── ltc_line.html      # Line light demo
│   ├── ltc_disk.html      # Disk light demo
│   └── shaders/           # GLSL implementations
└── external/              # Dependencies (glm, etc.)
```

## Key Entry Points

| File | Purpose |
|------|---------|
| `fit/fitLTC.cpp` | Generates LUT by fitting transformation matrices |
| `fit/LTC.h` | Core LTC evaluation and integration |
| `fit/brdf_ggx.h` | GGX microfacet BRDF (most common for specular) |
| `fit/results/ltc.h` | Pre-computed LUT data ready to use |
| `webgl/shaders/` | GLSL shader code for runtime evaluation |

## BRDF Support

The library includes fitting code for multiple BRDFs:

| BRDF | Use Case | Roughness Range |
|------|----------|----------------|
| **GGX** | Specular/metallic surfaces | 0.0 - 1.0 |
| **Beckmann** | Alternative specular (older games) | 0.0 - 1.0 |
| **Disney Diffuse** | Lambertian with retro-reflection | N/A (diffuse) |

Most modern renderers use **GGX** for specular and **Disney Diffuse** for the diffuse term.

## LUT Parameterization

The LUT is parameterized by:
- **Roughness** (alpha) - Surface roughness from smooth (0) to rough (1)
- **Theta** - Angle between view direction and surface normal

Each LUT entry stores:
- **M matrix** (3x3 transformation) - Stored as 4 floats (m11, m22, m13, m23) due to symmetry
- **Amplitude** - Energy normalization term
- **Fresnel term** - For view-dependent specular reflection

The original paper used different parameterization; this implementation optimizes for GPU texture lookups.

## Study Questions

- [x] What problem does LTC solve? → Fast area light integration
- [x] What are the key papers? → SIGGRAPH 2016 (quad), 2017 (line/disk)
- [x] What BRDFs are supported? → GGX, Beckmann, Disney Diffuse
- [ ] How is the transformation matrix computed during fitting?
- [ ] What is the closed-form integral for cosine over polygon?
- [ ] How do line and disk lights differ from polygonal lights?
- [ ] What are the memory requirements for LUTs?
- [ ] How does this compare to other area light techniques (LPV, voxel cone tracing)?
- [ ] Can LTC be extended to textured/emissive area lights?
- [ ] How would this integrate with a Rust/wgpu rendering pipeline?

## Documents to Create

- [ ] `architecture.md` — Fitting process, LUT structure, runtime evaluation
- [ ] `mathematics.md` — Transformation theory, integral derivations
- [ ] `shader-integration.md` — GLSL code walkthrough, GPU implementation
- [ ] `performance-analysis.md` — Benchmarks, memory usage, optimization tips
- [ ] `light-types.md` — Quad, line, disk implementation differences
- [ ] `code-traces/` — Annotated walkthrough of specific features
  - [ ] `fitting-process.md` - How fitLTC.cpp generates LUTs
  - [ ] `quad-evaluation.md` - Runtime shader evaluation for quad lights
  - [ ] `line-evaluation.md` - Runtime shader evaluation for line lights

## Comparison with Other Techniques

| Technique | Quality | Performance | Memory | Complexity |
|-----------|---------|-------------|--------|------------|
| **Point Lights** | Poor (no area) | Fastest | None | Trivial |
| **LTC** | High | Fast (2-3ms) | ~256KB LUT | Medium |
| **Monte Carlo** | Perfect | Slow (>100ms) | None | Low (random samples) |
| **Lightmaps** | High | Fastest | High (textures) | Baking required |
| **Voxel Cone Tracing** | Medium | Medium | Very high (3D grid) | High |

LTC occupies a sweet spot: near-photorealistic quality with real-time performance.

## Production Usage

Known implementations in production:
- **Frostbite** - First major engine adoption (2016)
- **Unity** - Built-in area light support (2017+)
- **Unreal Engine** - Path tracer area lights
- **Arnold** - Offline renderer acceleration

## Related Papers

1. **Real-Time Polygonal-Light Shading with Linearly Transformed Cosines** (2016)
   - Heitz, Dupuy, Hill, Neubelt
   - Original LTC formulation for quad lights

2. **Real-Time Area Lighting: a Journey From Research to Production** (2016)
   - Hill, Heitz
   - Production integration insights (Frostbite)

3. **Linear-Light Shading with Linearly Transformed Cosines** (2017)
   - Unity blog post extending to line lights

4. **Real-Time Line- and Disk-Light Shading** (2017)
   - Heitz, Hill
   - Extension to non-polygonal area lights

## References

- [LTC GitHub Repository](https://github.com/selfshadow/ltc_code)
- [WebGL Quad Demo](http://blog.selfshadow.com/ltc/webgl/ltc_quad.html)
- [WebGL Line Demo](http://blog.selfshadow.com/ltc/webgl/ltc_line.html)
- [WebGL Disk Demo](http://blog.selfshadow.com/ltc/webgl/ltc_disk.html)
- [Eric Heitz's Research Page](https://eheitzresearch.wordpress.com/415-2/)
- [Stephen Hill's Blog (Self Shadow)](https://blog.selfshadow.com/)
