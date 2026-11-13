# Texture Binding

This document describes how TexGen outputs connect to material texture slots.

## Binding Flow

```
Material Instance
  texture_bindings: {
    "albedo_metalness": "brushed_metal/base",
    "normal_roughness": "brushed_metal/normal"
  }
        │
        ▼
TexGen Output Registry
  outputs: {
    "brushed_metal/base": TextureHandle(42),
    "brushed_metal/normal": TextureHandle(43)
  }
        │
        ▼
Resolved Texture Array
  [0] = TextureHandle(42)  // slot 0: albedo_metalness
  [1] = TextureHandle(43)  // slot 1: normal_roughness
  [2] = fallback_emissive  // slot 2: no binding
        │
        ▼
Bind Group Creation
  @binding(0) = pool.get_view(handle_42)
  @binding(1) = pool.get_view(handle_43)
  @binding(2) = pool.get_view(fallback)
```

## Texture Slot Mapping

Phoenix uses 8 texture slots with specific PBR meanings:

| Slot | Name | WGSL Binding | PBR Usage |
|------|------|--------------|-----------|
| 0 | `albedo_metalness` | `@binding(0)` | RGB = albedo, A = metalness |
| 1 | `normal_roughness` | `@binding(1)` | RGB = normal, A = roughness |
| 2 | `emissive_alpha` | `@binding(2)` | RGB = emissive, A = opacity |
| 3 | `texture3` | `@binding(3)` | Custom (vertex offset, etc.) |
| 4 | `texture4` | `@binding(4)` | Custom |
| 5 | `texture5` | `@binding(5)` | Custom |
| 6 | `texture6` | `@binding(6)` | Custom / 3D texture |
| 7 | `texture7` | `@binding(7)` | Custom / depth texture |

## TexGen Output Registry

```rust
use std::collections::HashMap;

/// Registry of TexGen outputs available for material binding.
pub struct TexgenOutputRegistry {
    /// Named outputs → texture handles
    outputs: HashMap<String, TextureHandle>,

    /// Texture pool for handle resolution
    pool: TexturePool,
}

impl TexgenOutputRegistry {
    pub fn new(pool: TexturePool) -> Self {
        Self {
            outputs: HashMap::new(),
            pool,
        }
    }

    /// Register outputs from a TexGen graph evaluation.
    pub fn register_graph(&mut self, graph_name: &str, outputs: HashMap<String, TextureHandle>) {
        for (output_name, handle) in outputs {
            let full_path = format!("{}/{}", graph_name, output_name);
            self.outputs.insert(full_path, handle);
        }
    }

    /// Lookup a texture by path.
    pub fn get(&self, path: &str) -> Option<TextureHandle> {
        self.outputs.get(path).copied()
    }

    /// Get texture view by path.
    pub fn get_view(&self, path: &str) -> Option<&wgpu::TextureView> {
        self.get(path).map(|h| self.pool.get_view(h))
    }

    /// Check if a path exists.
    pub fn contains(&self, path: &str) -> bool {
        self.outputs.contains_key(path)
    }

    /// List all registered paths.
    pub fn paths(&self) -> impl Iterator<Item = &str> {
        self.outputs.keys().map(|s| s.as_str())
    }
}
```

## Texture Resolution

```rust
impl MaterialResolver {
    /// Resolve texture bindings to handles.
    pub fn resolve_textures(
        &self,
        instance: &MaterialInstance,
    ) -> Result<[TextureHandle; 8], String> {
        let mut textures = [TextureHandle::INVALID; 8];

        // Map slot names to indices
        let slot_map: HashMap<&str, usize> = [
            ("albedo_metalness", 0),
            ("normal_roughness", 1),
            ("emissive_alpha", 2),
            ("texture0", 0),  // Alternate names
            ("texture1", 1),
            ("texture2", 2),
            ("texture3", 3),
            ("texture4", 4),
            ("texture5", 5),
            ("texture6", 6),
            ("texture7", 7),
        ].into_iter().collect();

        // Process bindings
        for (slot_name, texgen_path) in &instance.texture_bindings {
            let slot_index = slot_map.get(slot_name.as_str())
                .ok_or_else(|| format!("Unknown texture slot: {}", slot_name))?;

            let handle = self.texgen_registry.get(texgen_path)
                .ok_or_else(|| format!(
                    "TexGen output not found: {} (for slot {})",
                    texgen_path, slot_name
                ))?;

            textures[*slot_index] = handle;
        }

        // Apply fallbacks for unbound slots
        self.apply_fallbacks(&mut textures);

        Ok(textures)
    }

    /// Apply fallback textures to unbound slots.
    fn apply_fallbacks(&self, textures: &mut [TextureHandle; 8]) {
        // Slot 0: White if no albedo
        if !textures[0].is_valid() {
            textures[0] = self.fallback_albedo;
        }

        // Slot 1: Neutral normal if no normal map
        if !textures[1].is_valid() {
            textures[1] = self.fallback_normal;
        }

        // Slot 2: Black if no emissive
        if !textures[2].is_valid() {
            textures[2] = self.fallback_emissive;
        }

        // Slots 3-7: Use fallback albedo (neutral)
        for i in 3..8 {
            if !textures[i].is_valid() {
                textures[i] = self.fallback_albedo;
            }
        }
    }
}
```

## Fallback Texture Creation

```rust
fn create_fallback_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    color: [u8; 4],
    label: &str,
) -> TextureHandle {
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });

    queue.write_texture(
        wgpu::ImageCopyTexture {
            texture: &texture,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        &color,
        wgpu::ImageDataLayout {
            offset: 0,
            bytes_per_row: Some(4),
            rows_per_image: Some(1),
        },
        wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
    );

    // Return handle (implementation depends on pool integration)
    TextureHandle::INVALID  // Placeholder
}

/// Standard fallback colors.
pub mod fallback_colors {
    /// White (diffuse default, metal = 0)
    pub const WHITE: [u8; 4] = [255, 255, 255, 0];

    /// Neutral normal (pointing up in tangent space)
    pub const NORMAL_UP: [u8; 4] = [128, 128, 255, 128];

    /// Black (no emission)
    pub const BLACK: [u8; 4] = [0, 0, 0, 255];

    /// Gray (medium roughness/metalness)
    pub const GRAY: [u8; 4] = [128, 128, 128, 128];
}
```

## Bind Group Creation

```rust
impl MaterialResolver {
    /// Create material bind group from resolved textures.
    pub fn create_bind_group(
        &self,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        textures: &[TextureHandle; 8],
        uniforms: &wgpu::Buffer,
    ) -> wgpu::BindGroup {
        // Get views for each slot
        let views: Vec<&wgpu::TextureView> = textures.iter()
            .map(|&h| self.pool.get_view(h))
            .collect();

        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Material Bind Group"),
            layout,
            entries: &[
                // Texture 0: Albedo + Metalness
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(views[0]),
                },
                // Texture 1: Normal + Roughness
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(views[1]),
                },
                // Texture 2: Emissive + Alpha
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(views[2]),
                },
                // Sampler
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Sampler(&self.material_sampler),
                },
                // Material uniforms
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: uniforms.as_entire_binding(),
                },
            ],
        })
    }
}
```

## Bind Group Layout

```rust
pub fn create_material_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Material Bind Group Layout"),
        entries: &[
            // Texture 0: Albedo + Metalness
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Texture 1: Normal + Roughness
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Texture 2: Emissive + Alpha
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Sampler
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            // Material uniforms
            wgpu::BindGroupLayoutEntry {
                binding: 4,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: Some(
                        std::num::NonZeroU64::new(
                            std::mem::size_of::<MaterialUniforms>() as u64
                        ).unwrap()
                    ),
                },
                count: None,
            },
        ],
    })
}
```

## WGSL Material Sampling

```wgsl
// material.wgsl

@group(2) @binding(0) var albedo_metalness: texture_2d<f32>;
@group(2) @binding(1) var normal_roughness: texture_2d<f32>;
@group(2) @binding(2) var emissive_alpha: texture_2d<f32>;
@group(2) @binding(3) var material_sampler: sampler;
@group(2) @binding(4) var<uniform> material: MaterialUniforms;

struct MaterialSample {
    albedo: vec3<f32>,
    metalness: f32,
    normal: vec3<f32>,
    roughness: f32,
    emissive: vec3<f32>,
    alpha: f32,
}

fn sample_material(uv: vec2<f32>) -> MaterialSample {
    var result: MaterialSample;

    // Sample textures
    let am = textureSample(albedo_metalness, material_sampler, uv);
    let nr = textureSample(normal_roughness, material_sampler, uv);
    let ea = textureSample(emissive_alpha, material_sampler, uv);

    // Unpack PBR parameters
    result.albedo = am.rgb;
    result.metalness = am.a * material.metalness_mod;

    // Decode normal from [0,1] to [-1,1]
    result.normal = normalize(nr.rgb * 2.0 - 1.0);
    result.normal.y *= material.invert_normal_y;

    result.roughness = nr.a * material.roughness_mod;

    result.emissive = ea.rgb * material.emissive_intensity;
    result.alpha = ea.a;

    return result;
}
```

## Format Validation

```rust
impl MaterialResolver {
    /// Validate texture format compatibility.
    pub fn validate_texture_format(
        &self,
        slot: usize,
        handle: TextureHandle,
    ) -> Result<(), String> {
        let is_hdr = self.pool.is_hdr(handle);
        let resolution = self.pool.get_resolution(handle);

        // Slot-specific requirements
        match slot {
            0 => {
                // Albedo: typically sRGB/LDR
                if is_hdr {
                    // Warning but allow - might be intentional
                }
            }
            1 => {
                // Normal: benefits from higher precision
                // HDR is fine
            }
            2 => {
                // Emissive: HDR recommended for glow effects
            }
            _ => {}
        }

        Ok(())
    }
}
```

## Related Documents

- [01-data-structures.md](01-data-structures.md) - TextureHandle definition
- [02-parameter-merging.md](02-parameter-merging.md) - How texture bindings are specified
- [04-pipeline-generation.md](04-pipeline-generation.md) - Bind group integration
- [../rust-port-texgen/03-texture-pool.md](../rust-port-texgen/03-texture-pool.md) - Pool implementation
