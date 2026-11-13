# Parameter Merging

This document describes how technique defaults and instance overrides combine to produce final material parameters.

## Merge Strategy

```
Technique Defaults          Instance Overrides
      │                           │
      │   for each param:         │
      │   ┌───────────────────────┼─────────────────┐
      │   │  override exists?     │                 │
      │   │         │             │                 │
      │   │    ┌────┴────┐        │                 │
      │   │   Yes       No        │                 │
      │   │    │         │        │                 │
      │   │    ▼         ▼        │                 │
      │   │ use override  use default              │
      │   └───────────────────────┼─────────────────┘
      │                           │
      ▼                           ▼
         Resolved Parameter Set
```

## Material Resolver

```rust
use std::collections::HashMap;

/// Resolves material instances to final parameter sets.
pub struct MaterialResolver {
    /// Loaded techniques by name
    techniques: HashMap<String, RenderTechnique>,

    /// TexGen evaluator for texture resolution
    texgen: TexgenEvaluator,

    /// Fallback textures
    fallback_albedo: TextureHandle,
    fallback_normal: TextureHandle,
    fallback_emissive: TextureHandle,
}

impl MaterialResolver {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Self {
        // Create 1×1 fallback textures
        let fallback_albedo = create_fallback_texture(
            device, queue,
            [255, 255, 255, 255],  // White
            "Fallback Albedo"
        );

        let fallback_normal = create_fallback_texture(
            device, queue,
            [128, 128, 255, 255],  // Normal pointing up
            "Fallback Normal"
        );

        let fallback_emissive = create_fallback_texture(
            device, queue,
            [0, 0, 0, 0],  // No emission
            "Fallback Emissive"
        );

        Self {
            techniques: HashMap::new(),
            texgen: TexgenEvaluator::new(device.clone().into(), queue.clone().into()),
            fallback_albedo,
            fallback_normal,
            fallback_emissive,
        }
    }

    /// Register a technique
    pub fn add_technique(&mut self, technique: RenderTechnique) {
        self.techniques.insert(technique.name.clone(), technique);
    }

    /// Resolve an instance to final parameters
    pub fn resolve(&self, instance: &MaterialInstance) -> Result<ResolvedMaterial, String> {
        // Get technique
        let technique = self.techniques.get(&instance.technique_name)
            .ok_or_else(|| format!("Unknown technique: {}", instance.technique_name))?;

        // Merge parameters
        let merged = self.merge_parameters(technique, instance)?;

        // Extract pipeline state
        let pipeline_key = self.extract_pipeline_key(&merged, technique)?;

        // Resolve textures
        let textures = self.resolve_textures(instance)?;

        // Collect numeric parameters
        let (float_params, color_params) = self.collect_numeric_params(&merged)?;

        // Get render priority
        let render_priority = match merged.get("render_priority") {
            Some(MaterialValue::RenderPriority(p)) => *p,
            _ => 0,
        };

        Ok(ResolvedMaterial {
            pipeline_key,
            textures,
            float_params,
            color_params,
            render_priority,
        })
    }
}
```

## Parameter Merge Algorithm

```rust
impl MaterialResolver {
    /// Merge technique defaults with instance overrides.
    fn merge_parameters(
        &self,
        technique: &RenderTechnique,
        instance: &MaterialInstance,
    ) -> Result<HashMap<String, MaterialValue>, String> {
        let mut result = HashMap::new();

        // Start with all technique defaults
        for param_def in &technique.parameters {
            result.insert(param_def.name.clone(), param_def.default.clone());
        }

        // Apply overrides
        for (name, value) in &instance.overrides {
            // Validate: override must match default type
            if let Some(param_def) = technique.get_param(name) {
                if !self.types_compatible(&param_def.default, value) {
                    return Err(format!(
                        "Type mismatch for parameter '{}': expected {:?}, got {:?}",
                        name,
                        std::mem::discriminant(&param_def.default),
                        std::mem::discriminant(value)
                    ));
                }

                // Check scope allows override
                if param_def.scope == ParamScope::Constant {
                    // Warning: constant parameters shouldn't be overridden
                    // But we allow it for flexibility
                }

                result.insert(name.clone(), value.clone());
            } else {
                // Override for unknown parameter - warning but allow
                result.insert(name.clone(), value.clone());
            }
        }

        Ok(result)
    }

    /// Check if two MaterialValues have compatible types.
    fn types_compatible(&self, a: &MaterialValue, b: &MaterialValue) -> bool {
        std::mem::discriminant(a) == std::mem::discriminant(b)
    }
}
```

## Pipeline Key Extraction

```rust
impl MaterialResolver {
    /// Extract pipeline state parameters into a cache key.
    fn extract_pipeline_key(
        &self,
        params: &HashMap<String, MaterialValue>,
        technique: &RenderTechnique,
    ) -> Result<PipelineKey, String> {
        let mut key = PipelineKey::default();

        // Shader ID from technique
        key.shader_id = self.hash_shader_name(&technique.vertex_shader, &technique.fragment_shader);

        // Blend mode
        if let Some(MaterialValue::BlendMode(mode)) = params.get("blend_mode") {
            key.blend_mode = *mode;
        }

        // Z mode
        if let Some(MaterialValue::ZMode(mode)) = params.get("z_mode") {
            key.z_mode = *mode;
        }

        // Z function
        if let Some(MaterialValue::ZFunction(func)) = params.get("z_function") {
            key.z_function = *func;
        }

        // Cull mode
        if let Some(MaterialValue::CullMode(mode)) = params.get("cull_mode") {
            key.cull_mode = *mode;
        }

        // Wireframe
        if let Some(MaterialValue::FillMode { wireframe }) = params.get("fill_mode") {
            key.wireframe = *wireframe;
        }

        // Color formats based on target layer
        key.color_formats = match technique.target_layer.as_str() {
            "solid" => vec![
                wgpu::TextureFormat::Rgba8Unorm,   // RT0: Albedo + Metal
                wgpu::TextureFormat::Rgba16Float,  // RT1: Normal + Rough
            ],
            "lighting" => vec![wgpu::TextureFormat::Rgba16Float],
            "transparent" => vec![wgpu::TextureFormat::Rgba8Unorm],
            _ => vec![wgpu::TextureFormat::Rgba8Unorm],
        };

        Ok(key)
    }

    fn hash_shader_name(&self, vs: &str, fs: &str) -> u64 {
        use std::hash::{Hash, Hasher};
        use std::collections::hash_map::DefaultHasher;

        let mut hasher = DefaultHasher::new();
        vs.hash(&mut hasher);
        fs.hash(&mut hasher);
        hasher.finish()
    }
}
```

## Numeric Parameter Collection

```rust
impl MaterialResolver {
    /// Collect float and color parameters for GPU upload.
    fn collect_numeric_params(
        &self,
        params: &HashMap<String, MaterialValue>,
    ) -> Result<(Vec<f32>, Vec<[f32; 4]>), String> {
        let mut floats = Vec::new();
        let mut colors = Vec::new();

        // Collect in deterministic order (sorted by name)
        let mut sorted_names: Vec<_> = params.keys().collect();
        sorted_names.sort();

        for name in sorted_names {
            match params.get(name) {
                Some(MaterialValue::Float(f)) => floats.push(*f),
                Some(MaterialValue::Color { r, g, b, a }) => colors.push([*r, *g, *b, *a]),
                _ => {}  // Non-numeric parameters handled elsewhere
            }
        }

        Ok((floats, colors))
    }
}
```

## Material Uniforms Generation

```rust
impl ResolvedMaterial {
    /// Create GPU-uploadable uniform data from resolved parameters.
    pub fn to_uniforms(&self) -> MaterialUniforms {
        let mut uniforms = MaterialUniforms::default();

        // Map resolved parameters to uniform fields
        // This depends on your specific uniform layout

        // Example: assuming floats are ordered [roughness_mod, metalness_mod, ...]
        if let Some(&roughness) = self.float_params.get(0) {
            uniforms.roughness_mod = roughness;
        }
        if let Some(&metalness) = self.float_params.get(1) {
            uniforms.metalness_mod = metalness;
        }

        // Example: assuming first color is tint
        if let Some(&tint) = self.color_params.get(0) {
            uniforms.tint = tint;
        }

        uniforms
    }
}
```

## Default Value Lookup

```rust
/// Standard default values for common parameter types.
pub struct DefaultValues;

impl DefaultValues {
    pub fn for_type(param_type: ParamType) -> MaterialValue {
        match param_type {
            ParamType::Float => MaterialValue::Float(0.0),
            ParamType::Color => MaterialValue::Color {
                r: 1.0, g: 1.0, b: 1.0, a: 1.0,
            },
            ParamType::ZMode => MaterialValue::ZMode(ZMode::ReadWrite),
            ParamType::ZFunction => MaterialValue::ZFunction(ZFunction::LessEqual),
            ParamType::FillMode => MaterialValue::FillMode { wireframe: false },
            ParamType::CullMode => MaterialValue::CullMode(CullMode::Back),
            ParamType::RenderPriority => MaterialValue::RenderPriority(0),
            ParamType::BlendMode0 | ParamType::BlendMode1 | ParamType::BlendMode2 |
            ParamType::BlendMode3 | ParamType::BlendMode4 | ParamType::BlendMode5 |
            ParamType::BlendMode6 | ParamType::BlendMode7 => {
                MaterialValue::BlendMode(BlendMode::OPAQUE)
            }
            ParamType::Texture0 | ParamType::Texture1 | ParamType::Texture2 |
            ParamType::Texture3 | ParamType::Texture4 | ParamType::Texture5 |
            ParamType::Texture6 | ParamType::Texture7 | ParamType::DepthTexture7 |
            ParamType::Texture3D6 => {
                MaterialValue::Texture(None)
            }
            _ => MaterialValue::Float(0.0),
        }
    }
}
```

## Validation

```rust
impl MaterialResolver {
    /// Validate a material instance against its technique.
    pub fn validate(&self, instance: &MaterialInstance) -> Vec<String> {
        let mut warnings = Vec::new();

        // Check technique exists
        let technique = match self.techniques.get(&instance.technique_name) {
            Some(t) => t,
            None => {
                warnings.push(format!(
                    "Unknown technique: {}",
                    instance.technique_name
                ));
                return warnings;
            }
        };

        // Check override types
        for (name, value) in &instance.overrides {
            if let Some(param_def) = technique.get_param(name) {
                if !self.types_compatible(&param_def.default, value) {
                    warnings.push(format!(
                        "Type mismatch: {} expects {:?}",
                        name,
                        std::mem::discriminant(&param_def.default)
                    ));
                }

                if param_def.scope == ParamScope::Constant {
                    warnings.push(format!(
                        "Overriding constant parameter: {}",
                        name
                    ));
                }
            } else {
                warnings.push(format!("Unknown parameter: {}", name));
            }
        }

        // Check required textures
        for param_def in &technique.parameters {
            if param_def.param_type.is_texture() {
                let slot_name = &param_def.name;
                if !instance.texture_bindings.contains_key(slot_name) {
                    if matches!(param_def.default, MaterialValue::Texture(None)) {
                        warnings.push(format!(
                            "Missing texture binding: {}",
                            slot_name
                        ));
                    }
                }
            }
        }

        warnings
    }
}
```

## Related Documents

- [01-data-structures.md](01-data-structures.md) - Type definitions
- [03-texture-binding.md](03-texture-binding.md) - Texture resolution
- [04-pipeline-generation.md](04-pipeline-generation.md) - Pipeline creation
