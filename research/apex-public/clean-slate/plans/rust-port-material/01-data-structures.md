# Material System Data Structures

This document defines Rust types for representing material techniques, instances, parameters, and their resolution.

## Dependencies

```toml
[dependencies]
wgpu = "0.19"
bytemuck = { version = "1.14", features = ["derive"] }
glam = "0.25"
serde = { version = "1.0", features = ["derive"] }
uuid = { version = "1.0", features = ["serde"] }
```

## Parameter Types Enum

Phoenix defines ~25 parameter types. This enum mirrors `MATERIALPARAMTYPE`:

```rust
use serde::{Deserialize, Serialize};

/// All material parameter types from Phoenix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum ParamType {
    // Numeric parameters
    Float = 0,
    Color = 1,

    // Pipeline state parameters
    ZMode = 2,
    ZFunction = 3,
    FillMode = 4,
    CullMode = 5,
    RenderPriority = 6,

    // Texture slots (8 slots)
    Texture0 = 7,
    Texture1 = 8,
    Texture2 = 9,
    Texture3 = 10,
    Texture4 = 11,
    Texture5 = 12,
    Texture6 = 13,
    Texture7 = 14,

    // Blend modes (per render target)
    BlendMode0 = 15,
    BlendMode1 = 16,
    BlendMode2 = 17,
    BlendMode3 = 18,
    BlendMode4 = 19,
    BlendMode5 = 20,
    BlendMode6 = 21,
    BlendMode7 = 22,

    // Special parameters
    RenderTarget = 23,
    ParticleLifeFloat = 24,
    DepthTexture7 = 25,
    Texture3D6 = 26,
    MeshData0 = 27,
    MeshData1 = 28,
    MeshData2 = 29,
    MeshData3 = 30,
    ParticleLife = 31,
    Ltc1 = 32,
    Ltc2 = 33,
}

impl ParamType {
    /// Is this a texture parameter?
    pub fn is_texture(&self) -> bool {
        matches!(
            self,
            ParamType::Texture0 | ParamType::Texture1 | ParamType::Texture2 |
            ParamType::Texture3 | ParamType::Texture4 | ParamType::Texture5 |
            ParamType::Texture6 | ParamType::Texture7 | ParamType::DepthTexture7 |
            ParamType::Texture3D6
        )
    }

    /// Is this a pipeline state parameter?
    pub fn is_pipeline_state(&self) -> bool {
        matches!(
            self,
            ParamType::ZMode | ParamType::ZFunction | ParamType::FillMode |
            ParamType::CullMode | ParamType::BlendMode0 | ParamType::BlendMode1 |
            ParamType::BlendMode2 | ParamType::BlendMode3 | ParamType::BlendMode4 |
            ParamType::BlendMode5 | ParamType::BlendMode6 | ParamType::BlendMode7
        )
    }

    /// Is this a numeric parameter (uploadable to GPU)?
    pub fn is_numeric(&self) -> bool {
        matches!(self, ParamType::Float | ParamType::Color)
    }

    /// Get texture slot index (0-7) for texture types
    pub fn texture_slot(&self) -> Option<u8> {
        match self {
            ParamType::Texture0 => Some(0),
            ParamType::Texture1 => Some(1),
            ParamType::Texture2 => Some(2),
            ParamType::Texture3 => Some(3),
            ParamType::Texture4 => Some(4),
            ParamType::Texture5 => Some(5),
            ParamType::Texture6 => Some(6),
            ParamType::Texture7 => Some(7),
            _ => None,
        }
    }
}
```

## Material Value Union

Phoenix stores parameters in a union. Rust uses an enum:

```rust
use uuid::Uuid;

/// Z-buffer mode configuration
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ZMode {
    /// Depth testing and writing disabled
    Disabled,
    /// Normal depth test and write
    #[default]
    ReadWrite,
    /// Depth test only, no write (for transparent objects)
    ReadOnly,
}

impl From<u8> for ZMode {
    fn from(byte: u8) -> Self {
        match byte {
            0 => ZMode::Disabled,
            1 => ZMode::ReadWrite,
            2 => ZMode::ReadOnly,
            _ => ZMode::ReadWrite,
        }
    }
}

/// Depth comparison function
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ZFunction {
    #[default]
    LessEqual,
    Never,
    Less,
    Equal,
    Greater,
    NotEqual,
    GreaterEqual,
    Always,
}

impl From<u8> for ZFunction {
    fn from(byte: u8) -> Self {
        match byte {
            0 => ZFunction::LessEqual,
            1 => ZFunction::Never,
            2 => ZFunction::Less,
            3 => ZFunction::Equal,
            4 => ZFunction::Greater,
            5 => ZFunction::NotEqual,
            6 => ZFunction::GreaterEqual,
            7 => ZFunction::Always,
            _ => ZFunction::LessEqual,
        }
    }
}

impl ZFunction {
    pub fn to_wgpu(&self) -> wgpu::CompareFunction {
        match self {
            ZFunction::LessEqual => wgpu::CompareFunction::LessEqual,
            ZFunction::Never => wgpu::CompareFunction::Never,
            ZFunction::Less => wgpu::CompareFunction::Less,
            ZFunction::Equal => wgpu::CompareFunction::Equal,
            ZFunction::Greater => wgpu::CompareFunction::Greater,
            ZFunction::NotEqual => wgpu::CompareFunction::NotEqual,
            ZFunction::GreaterEqual => wgpu::CompareFunction::GreaterEqual,
            ZFunction::Always => wgpu::CompareFunction::Always,
        }
    }
}

/// Face culling mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CullMode {
    /// No culling (two-sided)
    None,
    /// Cull front faces
    Front,
    /// Cull back faces (default)
    #[default]
    Back,
}

impl From<u8> for CullMode {
    fn from(byte: u8) -> Self {
        match byte {
            0 | 1 => CullMode::None,  // D3D11_CULL_NONE = 1
            2 => CullMode::Front,     // D3D11_CULL_FRONT = 2
            3 => CullMode::Back,      // D3D11_CULL_BACK = 3
            _ => CullMode::Back,
        }
    }
}

impl CullMode {
    pub fn to_wgpu(&self) -> Option<wgpu::Face> {
        match self {
            CullMode::None => None,
            CullMode::Front => Some(wgpu::Face::Front),
            CullMode::Back => Some(wgpu::Face::Back),
        }
    }
}

/// Blend mode encoded as packed byte.
/// Lower nibble = source factor, upper nibble = dest factor.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BlendMode(pub u8);

impl BlendMode {
    /// Opaque (replace, no blending): src=ONE, dst=ZERO
    pub const OPAQUE: Self = Self(0x01);
    /// Alpha blend: src=SRC_ALPHA, dst=INV_SRC_ALPHA
    pub const ALPHA: Self = Self(0x54);
    /// Additive: src=ONE, dst=ONE
    pub const ADDITIVE: Self = Self(0x11);
    /// Multiplicative: src=ZERO, dst=SRC_COLOR
    pub const MULTIPLY: Self = Self(0x80);

    /// Decode source blend factor
    pub fn src_factor(&self) -> wgpu::BlendFactor {
        Self::decode_factor(self.0 & 0x0F)
    }

    /// Decode destination blend factor
    pub fn dst_factor(&self) -> wgpu::BlendFactor {
        Self::decode_factor(self.0 >> 4)
    }

    fn decode_factor(nibble: u8) -> wgpu::BlendFactor {
        match nibble {
            0x0 => wgpu::BlendFactor::Zero,
            0x1 => wgpu::BlendFactor::One,
            0x2 => wgpu::BlendFactor::Src,
            0x3 => wgpu::BlendFactor::OneMinusSrc,
            0x4 => wgpu::BlendFactor::SrcAlpha,
            0x5 => wgpu::BlendFactor::OneMinusSrcAlpha,
            0x6 => wgpu::BlendFactor::DstAlpha,
            0x7 => wgpu::BlendFactor::OneMinusDstAlpha,
            0x8 => wgpu::BlendFactor::Dst,
            0x9 => wgpu::BlendFactor::OneMinusDst,
            0xA => wgpu::BlendFactor::SrcAlphaSaturated,
            _ => wgpu::BlendFactor::One,
        }
    }

    /// Convert to wgpu BlendState
    pub fn to_wgpu(&self) -> Option<wgpu::BlendState> {
        if *self == Self::OPAQUE {
            return None;  // No blending
        }

        Some(wgpu::BlendState {
            color: wgpu::BlendComponent {
                src_factor: self.src_factor(),
                dst_factor: self.dst_factor(),
                operation: wgpu::BlendOperation::Add,
            },
            alpha: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                operation: wgpu::BlendOperation::Add,
            },
        })
    }
}

/// Material parameter value (typed union).
#[derive(Debug, Clone, PartialEq)]
pub enum MaterialValue {
    /// Single float value
    Float(f32),

    /// RGBA color (each component 0.0-1.0)
    Color { r: f32, g: f32, b: f32, a: f32 },

    /// Depth buffer mode
    ZMode(ZMode),

    /// Depth comparison function
    ZFunction(ZFunction),

    /// Wireframe toggle
    FillMode { wireframe: bool },

    /// Face culling mode
    CullMode(CullMode),

    /// Draw order within layer
    RenderPriority(i32),

    /// Texture reference (TexGen output path)
    Texture(Option<String>),

    /// Blend mode (packed byte)
    BlendMode(BlendMode),
}

impl MaterialValue {
    /// Decode from binary representation.
    /// Binary format: 4 bytes type + 12 bytes value = 16 bytes total.
    pub fn from_bytes(param_type: ParamType, bytes: &[u8; 12]) -> Self {
        match param_type {
            ParamType::Float => {
                let value = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                MaterialValue::Float(value)
            }
            ParamType::Color => {
                let r = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                let g = f32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
                let b = f32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
                // Alpha might be in extended bytes or default to 1.0
                MaterialValue::Color { r, g, b, a: 1.0 }
            }
            ParamType::ZMode => {
                MaterialValue::ZMode(ZMode::from(bytes[0]))
            }
            ParamType::ZFunction => {
                MaterialValue::ZFunction(ZFunction::from(bytes[0]))
            }
            ParamType::CullMode => {
                MaterialValue::CullMode(CullMode::from(bytes[0]))
            }
            ParamType::FillMode => {
                MaterialValue::FillMode { wireframe: bytes[0] != 0 }
            }
            ParamType::RenderPriority => {
                let priority = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                MaterialValue::RenderPriority(priority)
            }
            ParamType::BlendMode0 | ParamType::BlendMode1 | ParamType::BlendMode2 |
            ParamType::BlendMode3 | ParamType::BlendMode4 | ParamType::BlendMode5 |
            ParamType::BlendMode6 | ParamType::BlendMode7 => {
                MaterialValue::BlendMode(BlendMode(bytes[0]))
            }
            ParamType::Texture0 | ParamType::Texture1 | ParamType::Texture2 |
            ParamType::Texture3 | ParamType::Texture4 | ParamType::Texture5 |
            ParamType::Texture6 | ParamType::Texture7 | ParamType::DepthTexture7 |
            ParamType::Texture3D6 => {
                // Texture references would be string paths in JSON
                MaterialValue::Texture(None)
            }
            _ => MaterialValue::Float(0.0),  // Default fallback
        }
    }
}
```

## Parameter Definition

```rust
/// Parameter scope (when the value can change)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ParamScope {
    /// Fixed at material creation
    #[default]
    Constant,
    /// Can differ per-instance
    Variable,
    /// Driven by animation splines
    Animated,
}

/// A named parameter definition within a technique.
#[derive(Debug, Clone)]
pub struct ParameterDef {
    /// Parameter name (for lookup)
    pub name: String,
    /// Parameter type
    pub param_type: ParamType,
    /// Parameter scope
    pub scope: ParamScope,
    /// Default value
    pub default: MaterialValue,
}

impl ParameterDef {
    pub fn new(name: impl Into<String>, param_type: ParamType, default: MaterialValue) -> Self {
        Self {
            name: name.into(),
            param_type,
            scope: ParamScope::Constant,
            default,
        }
    }

    pub fn with_scope(mut self, scope: ParamScope) -> Self {
        self.scope = scope;
        self
    }
}
```

## Render Technique

```rust
/// A render technique defines a reusable rendering recipe.
#[derive(Debug, Clone)]
pub struct RenderTechnique {
    /// Technique name (for reference)
    pub name: String,

    /// Technique type
    pub technique_type: TechniqueType,

    /// Parameter definitions with defaults
    pub parameters: Vec<ParameterDef>,

    /// Which render layer to target
    pub target_layer: String,

    /// Shader identifiers
    pub vertex_shader: String,
    pub fragment_shader: String,
}

/// Technique usage types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TechniqueType {
    /// Standard mesh rendering (G-Buffer)
    #[default]
    Material,
    /// Full-screen post-processing
    PostProcess,
    /// Procedural shadertoy-style effects
    Shadertoy,
    /// Particle system rendering
    Particle,
}

impl RenderTechnique {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            technique_type: TechniqueType::Material,
            parameters: Vec::new(),
            target_layer: "solid".into(),
            vertex_shader: String::new(),
            fragment_shader: String::new(),
        }
    }

    /// Add a parameter definition
    pub fn add_param(&mut self, def: ParameterDef) {
        self.parameters.push(def);
    }

    /// Get parameter definition by name
    pub fn get_param(&self, name: &str) -> Option<&ParameterDef> {
        self.parameters.iter().find(|p| p.name == name)
    }
}
```

## Material Instance

```rust
use std::collections::HashMap;

/// A material instance assigns a technique to a mesh with overrides.
#[derive(Debug, Clone)]
pub struct MaterialInstance {
    /// Unique identifier
    pub id: Uuid,

    /// Which mesh uses this material
    pub mesh_name: String,

    /// Which technique to use
    pub technique_name: String,

    /// Parameter overrides (name → value)
    pub overrides: HashMap<String, MaterialValue>,

    /// Texture bindings (slot name → TexGen output path)
    pub texture_bindings: HashMap<String, String>,
}

impl MaterialInstance {
    pub fn new(mesh_name: impl Into<String>, technique_name: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            mesh_name: mesh_name.into(),
            technique_name: technique_name.into(),
            overrides: HashMap::new(),
            texture_bindings: HashMap::new(),
        }
    }

    /// Set a parameter override
    pub fn set_override(&mut self, name: impl Into<String>, value: MaterialValue) {
        self.overrides.insert(name.into(), value);
    }

    /// Bind a texture slot to a TexGen output
    pub fn bind_texture(&mut self, slot: impl Into<String>, texgen_path: impl Into<String>) {
        self.texture_bindings.insert(slot.into(), texgen_path.into());
    }
}
```

## Resolved Material

```rust
/// A fully-resolved material ready for rendering.
#[derive(Debug)]
pub struct ResolvedMaterial {
    /// Pipeline state key (for pipeline cache lookup)
    pub pipeline_key: PipelineKey,

    /// Resolved texture handles (slot → TextureHandle)
    pub textures: [TextureHandle; 8],

    /// Collected float parameters for uniform upload
    pub float_params: Vec<f32>,

    /// Collected color parameters for uniform upload
    pub color_params: Vec<[f32; 4]>,

    /// Render priority (draw order)
    pub render_priority: i32,
}

/// Key for pipeline cache lookup.
/// Materials with the same key share the same pipeline.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PipelineKey {
    /// Shader identifiers
    pub shader_id: u64,

    /// Blend mode
    pub blend_mode: BlendMode,

    /// Depth test mode
    pub z_mode: ZMode,

    /// Depth comparison function
    pub z_function: ZFunction,

    /// Cull mode
    pub cull_mode: CullMode,

    /// Wireframe mode
    pub wireframe: bool,

    /// Target color formats
    pub color_formats: Vec<wgpu::TextureFormat>,

    /// Depth format
    pub depth_format: wgpu::TextureFormat,
}

impl Default for PipelineKey {
    fn default() -> Self {
        Self {
            shader_id: 0,
            blend_mode: BlendMode::OPAQUE,
            z_mode: ZMode::ReadWrite,
            z_function: ZFunction::LessEqual,
            cull_mode: CullMode::Back,
            wireframe: false,
            color_formats: vec![wgpu::TextureFormat::Rgba8Unorm],
            depth_format: wgpu::TextureFormat::Depth32Float,
        }
    }
}
```

## GPU Uniform Structures

```rust
use bytemuck::{Pod, Zeroable};

/// Material parameters uploaded to GPU.
/// Extends ObjectUniforms with material-specific data.
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct MaterialUniforms {
    /// Roughness modifier
    pub roughness_mod: f32,
    /// Metalness modifier
    pub metalness_mod: f32,
    /// Invert normal Y (for different tangent space conventions)
    pub invert_normal_y: f32,
    /// Emissive intensity multiplier
    pub emissive_intensity: f32,

    /// Tint color
    pub tint: [f32; 4],

    /// UV scale and offset
    pub uv_transform: [f32; 4],  // scale_x, scale_y, offset_x, offset_y
}

impl Default for MaterialUniforms {
    fn default() -> Self {
        Self {
            roughness_mod: 1.0,
            metalness_mod: 1.0,
            invert_normal_y: 1.0,
            emissive_intensity: 1.0,
            tint: [1.0, 1.0, 1.0, 1.0],
            uv_transform: [1.0, 1.0, 0.0, 0.0],
        }
    }
}
```

## WGSL Struct Definitions

```wgsl
// material_uniforms.wgsl

struct MaterialUniforms {
    roughness_mod: f32,
    metalness_mod: f32,
    invert_normal_y: f32,
    emissive_intensity: f32,
    tint: vec4<f32>,
    uv_transform: vec4<f32>,
}

// Bind group 2: Material textures + params
@group(2) @binding(0) var albedo_metalness: texture_2d<f32>;
@group(2) @binding(1) var normal_roughness: texture_2d<f32>;
@group(2) @binding(2) var emissive_alpha: texture_2d<f32>;
@group(2) @binding(3) var material_sampler: sampler;
@group(2) @binding(4) var<uniform> material: MaterialUniforms;
```

## JSON Parsing

```rust
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct TechniqueJson {
    pub name: String,
    #[serde(rename = "type")]
    pub technique_type: String,
    pub parameters: Vec<ParamDefJson>,
    pub target_layer: String,
    pub vertex_shader: Option<String>,
    pub fragment_shader: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ParamDefJson {
    pub name: String,
    #[serde(rename = "type")]
    pub param_type: String,
    pub scope: Option<String>,
    pub default: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct InstanceJson {
    pub mesh: String,
    pub technique: String,
    pub overrides: Option<HashMap<String, serde_json::Value>>,
    pub textures: Option<HashMap<String, String>>,
}

impl TechniqueJson {
    pub fn to_technique(&self) -> Result<RenderTechnique, String> {
        let mut tech = RenderTechnique::new(&self.name);

        tech.technique_type = match self.technique_type.as_str() {
            "material" => TechniqueType::Material,
            "postprocess" => TechniqueType::PostProcess,
            "shadertoy" => TechniqueType::Shadertoy,
            "particle" => TechniqueType::Particle,
            _ => TechniqueType::Material,
        };

        tech.target_layer = self.target_layer.clone();
        tech.vertex_shader = self.vertex_shader.clone().unwrap_or_default();
        tech.fragment_shader = self.fragment_shader.clone().unwrap_or_default();

        for param_json in &self.parameters {
            let param_type = parse_param_type(&param_json.param_type)?;
            let default = parse_default_value(&param_json.default, param_type)?;
            let scope = parse_scope(param_json.scope.as_deref());

            tech.add_param(
                ParameterDef::new(&param_json.name, param_type, default)
                    .with_scope(scope)
            );
        }

        Ok(tech)
    }
}

fn parse_param_type(s: &str) -> Result<ParamType, String> {
    match s.to_lowercase().as_str() {
        "float" => Ok(ParamType::Float),
        "color" => Ok(ParamType::Color),
        "zmode" => Ok(ParamType::ZMode),
        "zfunction" => Ok(ParamType::ZFunction),
        "fillmode" => Ok(ParamType::FillMode),
        "cullmode" => Ok(ParamType::CullMode),
        "texture0" => Ok(ParamType::Texture0),
        "texture1" => Ok(ParamType::Texture1),
        "texture2" => Ok(ParamType::Texture2),
        "blendmode0" => Ok(ParamType::BlendMode0),
        _ => Err(format!("Unknown param type: {}", s)),
    }
}

fn parse_scope(s: Option<&str>) -> ParamScope {
    match s {
        Some("constant") => ParamScope::Constant,
        Some("variable") => ParamScope::Variable,
        Some("animated") => ParamScope::Animated,
        _ => ParamScope::Constant,
    }
}

fn parse_default_value(value: &serde_json::Value, param_type: ParamType) -> Result<MaterialValue, String> {
    // Implementation depends on JSON structure
    Ok(MaterialValue::Float(0.0))  // Placeholder
}
```

## Related Documents

- [02-parameter-merging.md](02-parameter-merging.md) - How defaults and overrides combine
- [03-texture-binding.md](03-texture-binding.md) - TexGen integration
- [04-pipeline-generation.md](04-pipeline-generation.md) - Pipeline creation from PipelineKey
