# Expected Output Reference

This document describes what you should see at each stage of implementation. Use these descriptions to verify your pipeline is working correctly.

## Debug Visualization Modes

Before checking final output, implement these debug modes in your shaders:

```wgsl
// Add to lighting shader
@group(0) @binding(10) var<uniform> debug_mode: u32;

// In fragment shader:
switch debug_mode {
    case 1u: { return vec4<f32>(albedo, 1.0); }           // Albedo only
    case 2u: { return vec4<f32>(N * 0.5 + 0.5, 1.0); }    // World normals
    case 3u: { return vec4<f32>(vec3<f32>(roughness), 1.0); }  // Roughness
    case 4u: { return vec4<f32>(vec3<f32>(metallic), 1.0); }   // Metallic
    case 5u: { return vec4<f32>(vec3<f32>(depth_linear / 20.0), 1.0); }  // Depth
    case 6u: { return vec4<f32>(diffuse, 1.0); }          // Diffuse only
    case 7u: { return vec4<f32>(specular, 1.0); }         // Specular only
    default: { /* normal rendering */ }
}
```

---

## Phase 1: G-Buffer Pass

### Milestone 1.1: G-Buffer RT0 (Albedo + Metallic)

**Test**: Render the material grid scene, output RT0 directly.

**Expected**:
- Red spheres visible (the grid uses red albedo)
- Color should be flat/unlit (no shading yet)
- Alpha channel shows metallic gradient:
  - Bottom row: black (metallic = 0)
  - Top row: white (metallic = 1)
- Ground plane visible in gray

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| All black | Vertex shader broken | Check world matrix multiplication order |
| Upside down | Y-flip missing | Flip projection Y or UV Y |
| Wrong colors | sRGB double-conversion | Use Rgba8Unorm, not Rgba8UnormSrgb |

### Milestone 1.2: G-Buffer RT1 (Normal + Roughness)

**Test**: Output RT1 directly.

**Expected**:
- RGB shows world-space normals (remap: N*0.5+0.5)
  - Top of spheres: greenish (Y-up = 0.5, 1.0, 0.5)
  - Sides facing camera: bluish (Z-forward)
  - Ground plane: pure green (0.5, 1.0, 0.5)
- Alpha shows roughness gradient:
  - Left column: dark (roughness ≈ 0.1)
  - Right column: bright (roughness ≈ 0.9)

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| Flat normals | Normal not transformed | Apply inverse-transpose world matrix |
| Flickering normals | Precision issues | Use Rgba16Float format |
| Normals look faceted | Using flat normals | Check vertex normal generation |

### Milestone 1.3: Depth Visualization

**Test**: Sample depth buffer, linearize, output as grayscale.

**Expected**:
- Near objects (spheres): darker
- Far objects: lighter
- Smooth gradient, no banding
- Ground plane has consistent depth across surface

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| All white or black | Wrong near/far in linearization | Match camera near/far values |
| Depth reversed | Using wrong depth range | Check [0,1] vs [-1,1] formula |
| Can't sample depth | Wrong texture binding type | Use texture_depth_2d, not texture_2d |

### Milestone 1.4: World Position Reconstruction

**Test**: Reconstruct world position from depth, output as color (scaled).

**Expected**:
- X position → Red (left = dark, right = bright)
- Y position → Green (bottom = dark, top = bright)
- Z position → Blue (far = dark, near = bright)
- Spheres should show smooth position gradients
- Positions should match actual geometry placement

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| Positions wrong | Matrix inverse wrong | Check inverse_view and inverse_projection |
| Y flipped | Coordinate system mismatch | Flip Y in NDC calculation |
| Positions offset | Projection matrix issue | Verify perspective matrix is correct |

---

## Phase 2: Deferred Lighting

### Milestone 2.1: Single Point Light

**Test**: One point light, Lambertian diffuse only (no specular).

**Expected**:
- Spheres lit from light position
- Falloff visible (brighter near light, darker far)
- No harsh cutoff at attenuation radius (smooth falloff)
- Ground plane shows light pool

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| No lighting | World position wrong | Fix reconstruction (see 1.4) |
| Harsh circle edge | Using step() for attenuation | Use smooth falloff function |
| Light at wrong position | Light position in wrong space | Ensure world space |

### Milestone 2.2: Cook-Torrance Specular

**Test**: Add GGX specular to the point light.

**Expected (Material Grid)**:
- Bottom-left sphere: strong, sharp specular (smooth dielectric)
- Bottom-right sphere: weak, broad specular (rough dielectric)
- Top-left sphere: strong, tinted specular (smooth metal)
- Top-right sphere: weak, tinted specular (rough metal)
- Specular highlight moves as camera moves

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| No specular | Division by zero in BRDF | Add epsilon to denominators |
| Specular too bright | Missing normalization | Check D term denominator |
| Black at grazing angles | NdotV = 0 | Clamp NdotV to 0.0001 minimum |
| Metallic looks wrong | F0 calculation | F0 = lerp(0.04, albedo, metallic) |

### Milestone 2.3: Multiple Lights

**Test**: Add second point light with different color.

**Expected**:
- Both lights contribute (additive blending)
- Overlapping regions show mixed colors
- Each light has proper falloff
- No light "bleeding" outside attenuation radius

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| Only one light | Light loop wrong | Check light count uniform |
| Lights overwrite | Wrong blend mode | Use One/One additive blend |
| Performance drop | Looping all 8 lights | Only loop to light_count |

### Milestone 2.4: Ambient Pass

**Test**: Add ambient illumination.

**Expected**:
- Shadow areas no longer pure black
- Ambient adds subtle fill light
- Ambient tint visible in dark areas
- Metals should have reduced ambient (Fresnel-weighted)

---

## Phase 3: Shadow Mapping

### Milestone 3.1: Shadow Map Generation

**Test**: Visualize the shadow depth buffer directly.

**Expected**:
- Scene rendered from light's perspective
- Objects visible as depth values (gray gradient)
- Correct objects occluded from light's view

### Milestone 3.2: Basic Shadow Test

**Test**: Hard shadows (single sample).

**Expected (Shadow Test Scene)**:
- Ground shows shadow of sphere
- Small occluder casts shadow on large sphere
- Shadow edges are hard/aliased
- Areas behind objects are dark

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| Shadow in wrong place | Light matrix wrong | Check light view/projection construction |
| Self-shadowing artifacts | Shadow acne | Add depth bias |
| Peter panning | Too much bias | Reduce bias or use slope-scaled bias |
| Shadow reversed | Depth comparison wrong | Check LessEqual vs Greater |

### Milestone 3.3: PCF Soft Shadows

**Test**: Enable PCF with 5×5 kernel.

**Expected**:
- Shadow edges now soft/blurred
- Softness increases with PCF radius
- Performance slightly lower than hard shadows
- No visible grid pattern in shadow

---

## Phase 4: Area Lights (LTC)

### Milestone 4.1: LTC Texture Verification

**Test**: Sample LTC textures and visualize.

**Expected (Matrix Texture)**:
- 16×16 grid visible
- Values vary smoothly across texture
- No obvious corruption or solid colors

**Expected (Fresnel Texture)**:
- 16×16 grid visible
- Top portion (low roughness): high values
- Bottom portion (high roughness): lower values

### Milestone 4.2: Sphere Area Light

**Test**: Single sphere area light above the scene.

**Expected (Area Light Test Scene)**:
- Soft, realistic specular on ceramic sphere
- Specular shape matches sphere light (not point highlight)
- Metal sphere shows stretched reflection of light
- Rough surfaces show broader, dimmer reflection
- Smooth surfaces show tighter, brighter reflection

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| No specular | LTC matrix sample wrong | Check UV calculation (sqrt(1-cos)) |
| Specular too sharp | Using point light fallback | Verify polygon clipping works |
| Specular wrong shape | Matrix components swapped | Check RGBA → matrix reconstruction |

---

## Phase 5: Post-Processing

### Milestone 5.1: ACES Tone Mapping

**Test**: Apply ACES to HDR buffer.

**Expected**:
- Bright areas no longer clipped to white
- Overall image has filmic look
- Colors slightly desaturated in highlights
- Dark areas retain detail

**Before/After**:
- Before: Harsh clipping, oversaturated highlights
- After: Smooth rolloff, natural highlight color

### Milestone 5.2: Bloom

**Test**: Apply bloom to bright areas.

**Expected**:
- Light sources have soft glow
- Glow extends beyond source boundary
- Multiple blur passes visible (soft falloff)
- Bloom intensity adjustable

**Common Issues**:
| Symptom | Cause | Fix |
|---------|-------|-----|
| No bloom | Threshold too high | Lower threshold below scene brightness |
| Bloom too harsh | Missing Gaussian blur | Check blur kernel weights |
| Bloom square-shaped | Not separable blur | Use horizontal then vertical pass |

### Milestone 5.3: FXAA

**Test**: Apply FXAA to final image.

**Expected**:
- Jagged edges on sphere silhouettes smoothed
- Text/UI (if any) should remain sharp
- No significant blur on flat surfaces
- Performance impact minimal

### Milestone 5.4: Full Post-Processing Chain

**Test**: Enable all effects in order: SSAO → Lighting → Bloom → DoF → ACES → FXAA → Grain

**Expected**:
- SSAO: contact shadows in creases
- Bloom: light glow
- DoF: background blur (if focus set correctly)
- ACES: filmic tone curve
- FXAA: smooth edges
- Grain: subtle film grain overlay

---

## Material Test Grid Reference

When the full pipeline is working, the 5×5 material grid should show:

```
            Roughness →
         0.1   0.3   0.5   0.7   0.9
       ┌─────┬─────┬─────┬─────┬─────┐
  1.0  │ ●   │ ●   │ ●   │ ●   │ ●   │  Sharp    Broad
       │shiny│     │     │     │matte│  metal    metal
       ├─────┼─────┼─────┼─────┼─────┤  specular specular
  0.75 │ ●   │ ●   │ ●   │ ●   │ ●   │
       │     │     │     │     │     │
M      ├─────┼─────┼─────┼─────┼─────┤
e 0.5  │ ●   │ ●   │ ●   │ ●   │ ●   │
t      │     │     │     │     │     │
a      ├─────┼─────┼─────┼─────┼─────┤
l 0.25 │ ●   │ ●   │ ●   │ ●   │ ●   │
       │     │     │     │     │     │
↓      ├─────┼─────┼─────┼─────┼─────┤
  0.0  │ ●   │ ●   │ ●   │ ●   │ ●   │  Sharp    Diffuse
       │shiny│     │     │     │matte│  plastic  rubber
       └─────┴─────┴─────┴─────┴─────┘
```

**Visual characteristics**:
- **Bottom-left** (metallic=0, rough=0.1): Shiny plastic, small bright specular, visible diffuse
- **Bottom-right** (metallic=0, rough=0.9): Matte rubber, no visible specular, soft diffuse
- **Top-left** (metallic=1, rough=0.1): Polished metal, bright colored specular, no diffuse
- **Top-right** (metallic=1, rough=0.9): Brushed metal, broad colored specular, no diffuse
- **Metallic gradient**: Diffuse contribution decreases from bottom to top
- **Roughness gradient**: Specular gets broader and dimmer from left to right

---

## Quick Sanity Checks

Before investigating complex issues, verify these basics:

| Check | How | Expected |
|-------|-----|----------|
| Triangle renders | Draw single tri, output red | Red triangle on screen |
| Depth works | Enable depth test, draw two tris | Front tri visible |
| MRT works | Write to RT0 and RT1 | Both show different content |
| Uniform uploads | Set color uniform, use in shader | Color matches uniform value |
| Texture sampling | Sample test texture | Texture visible on geometry |
| Fullscreen triangle | Draw vertex_index 0,1,2 | Screen filled with color |

---

## Performance Baselines

Rough performance expectations (1080p, mid-range GPU):

| Stage | Time Budget | Notes |
|-------|-------------|-------|
| Shadow pass | 0.5-1.0 ms | Depth-only, should be fast |
| G-Buffer pass | 1-2 ms | Depends on triangle count |
| Lighting (8 lights) | 1-2 ms | Full-screen, compute bound |
| LTC area light | 0.5-1 ms | Per light |
| Post-processing (all) | 2-3 ms | Mostly fill-rate bound |
| **Total** | **5-9 ms** | ~110-200 FPS headroom |

If significantly slower, check:
- Are you creating resources every frame?
- Is light loop running for all 8 lights even with fewer?
- Are post-processing passes at full resolution?
- Is buffer mapping blocking the CPU?

---

## Related Documents

- [00-overview.md](../00-overview.md) - Implementation phases
- [appendix/pitfalls-troubleshooting.md](../appendix/pitfalls-troubleshooting.md) - Debug specific issues
- [geometry.rs](geometry.rs) - Test mesh generation
- [scene.rs](scene.rs) - Test scene configuration
