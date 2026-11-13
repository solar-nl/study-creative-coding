# TexGen Data Structures

This document defines the Rust structs, enums, and type definitions needed to represent TexGen operator graphs and manage their evaluation.

## Dependencies

```toml
[dependencies]
wgpu = "0.19"
bytemuck = { version = "1.14", features = ["derive"] }
glam = "0.25"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
```

## Resolution Encoding

Phoenix packs texture dimensions into a single byte using power-of-two exponents.

```rust
/// Texture resolution as power-of-two exponents.
///
/// Phoenix encodes both dimensions in one byte:
/// - High nibble (bits 4-7): width exponent
/// - Low nibble (bits 0-3): height exponent
///
/// Example: 0x88 = width 2^8 = 256, height 2^8 = 256
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TexgenResolution {
    /// Width exponent (2^width_power)
    pub width_power: u8,
    /// Height exponent (2^height_power)
    pub height_power: u8,
}

impl TexgenResolution {
    /// Create from explicit dimensions (must be power of two)
    pub fn new(width: u32, height: u32) -> Result<Self, String> {
        if !width.is_power_of_two() || !height.is_power_of_two() {
            return Err("Dimensions must be power of two".into());
        }
        Ok(Self {
            width_power: width.trailing_zeros() as u8,
            height_power: height.trailing_zeros() as u8,
        })
    }

    /// Create from packed byte (Phoenix format)
    pub fn from_packed(byte: u8) -> Self {
        Self {
            width_power: byte >> 4,
            height_power: byte & 0x0f,
        }
    }

    /// Convert to packed byte for serialization
    pub fn to_packed(&self) -> u8 {
        (self.width_power << 4) | (self.height_power & 0x0f)
    }

    /// Get actual width in pixels
    pub fn width(&self) -> u32 {
        1 << self.width_power
    }

    /// Get actual height in pixels
    pub fn height(&self) -> u32 {
        1 << self.height_power
    }

    /// Get as wgpu::Extent3d for texture creation
    pub fn extent(&self) -> wgpu::Extent3d {
        wgpu::Extent3d {
            width: self.width(),
            height: self.height(),
            depth_or_array_layers: 1,
        }
    }

    // Common presets
    pub const RES_16: Self = Self { width_power: 4, height_power: 4 };
    pub const RES_32: Self = Self { width_power: 5, height_power: 5 };
    pub const RES_64: Self = Self { width_power: 6, height_power: 6 };
    pub const RES_128: Self = Self { width_power: 7, height_power: 7 };
    pub const RES_256: Self = Self { width_power: 8, height_power: 8 };
    pub const RES_512: Self = Self { width_power: 9, height_power: 9 };
    pub const RES_1024: Self = Self { width_power: 10, height_power: 10 };
    pub const RES_2048: Self = Self { width_power: 11, height_power: 11 };
}

impl Default for TexgenResolution {
    fn default() -> Self {
        Self::RES_256
    }
}
```

## Operator Types

```rust
/// All supported TexGen operator types.
///
/// Categories:
/// - Generators (0 inputs): Create patterns from parameters
/// - Transforms (1 input): Modify UV coordinates
/// - Color ops (1 input): Adjust colors
/// - Blends (2 inputs): Combine textures
/// - Filters (1 input): Convolution/processing
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OperatorType {
    // === Generators (0 inputs) ===
    /// Multi-octave Perlin noise (FBM)
    Noise,
    /// Voronoi distance field with multi-pass propagation
    Cells,
    /// Single-pass Voronoi (classic algorithm)
    Cells2,
    /// Voronoi cell edge detection
    CellEdges,
    /// 6 geometric gradient patterns
    Gradient,
    /// Superellipse (rounded rectangle) SDF
    Rectangle,
    /// Constant RGBA fill
    SolidColor,
    /// Grid with brick pattern offset
    Tiles,
    /// Scattered sprite instances
    Sprinkle,
    /// Catmull-Rom interpolated plasma
    SubPlasma,
    /// Radial environment map falloff
    EnvMap,
    /// Text rendering (requires extra data)
    Text,

    // === Transforms (1 input) ===
    /// Rotation + zoom + pan
    Rotozoom,
    /// Simple UV offset
    Translate,
    /// Axis mirroring
    Mirror,
    /// Tile/repeat adjustment
    Loop,
    /// Quantize to grid
    Pixelize,
    /// Cartesian to polar coordinates
    ToPolar,
    /// UV distortion via displacement map
    MapDistort,

    // === Color Operations (1 input) ===
    /// Map grayscale to color gradient
    Colorize,
    /// Hue/Saturation/Lightness adjustment
    Hsl,
    /// Remap value range
    Scale,
    /// Contrast/brightness adjustment
    Contrast,
    /// Invert colors
    Invert,
    /// Spline-based color curves
    Curves,
    /// HSL-space curves
    HslCurves,
    /// Palette quantization
    Palette,
    /// Smoothstep threshold
    Smoothstep,

    // === Blend Operations (2 inputs) ===
    /// 10 blend modes (add, multiply, screen, overlay, etc.)
    Combine,
    /// Linear interpolation
    Mix,
    /// Per-pixel blend via mask
    MixMap,
    /// Replace alpha channel
    ReplaceAlpha,

    // === Filters (1 input) ===
    /// Separable Gaussian blur (2 passes)
    Blur,
    /// Directional motion blur
    DirBlur,
    /// Height to normal conversion (Sobel)
    Normalmap,
    /// UV distortion via turbulence
    Turbulence,
    /// Refraction normal for glass
    Glass,
}

impl OperatorType {
    /// Number of input textures required
    pub fn input_count(&self) -> usize {
        use OperatorType::*;
        match self {
            // Generators: no inputs
            Noise | Cells | Cells2 | CellEdges | Gradient | Rectangle |
            SolidColor | Tiles | Sprinkle | SubPlasma | EnvMap | Text => 0,

            // Transforms and single-input ops
            Rotozoom | Translate | Mirror | Loop | Pixelize | ToPolar |
            MapDistort | Colorize | Hsl | Scale | Contrast | Invert |
            Curves | HslCurves | Palette | Smoothstep | Blur | DirBlur |
            Normalmap | Turbulence | Glass => 1,

            // Blend operations (2 inputs)
            Combine | Mix | MixMap | ReplaceAlpha => 2,
        }
    }

    /// Number of render passes for this operator
    pub fn pass_count(&self) -> u8 {
        use OperatorType::*;
        match self {
            Noise => 8,        // Up to 8 octaves
            Cells => 16,       // Distance propagation iterations
            SubPlasma => 3,    // Horizontal, vertical, combine
            Blur => 6,         // 3 horizontal + 3 vertical
            _ => 1,            // Single pass
        }
    }

    /// Does this operator need the hash texture?
    pub fn needs_hash(&self) -> bool {
        use OperatorType::*;
        matches!(self, Noise | Cells | Cells2 | CellEdges | SubPlasma | Sprinkle)
    }

    /// Does this operator use random seed?
    pub fn needs_seed(&self) -> bool {
        use OperatorType::*;
        matches!(self, Noise | Cells | Cells2 | CellEdges | SubPlasma | Sprinkle)
    }
}
```

## Operator Parameters

```rust
/// Raw parameter storage (16 bytes, matching Phoenix format).
///
/// Parameters are stored as bytes (0-255) and normalized to 0.0-1.0
/// in shaders. Different operators interpret these bytes differently:
/// - Float: byte / 255.0
/// - Angle: byte * 255/256 * 2π
/// - Integer: byte as-is
/// - Color: 4 consecutive bytes as RGBA
#[derive(Debug, Clone, Copy, Default)]
pub struct OperatorParams {
    /// Raw parameter bytes
    pub bytes: [u8; 16],
}

impl OperatorParams {
    /// Create from byte array
    pub fn new(bytes: [u8; 16]) -> Self {
        Self { bytes }
    }

    /// Convert all parameters to normalized floats for GPU upload
    pub fn as_floats(&self) -> [f32; 16] {
        let mut result = [0.0f32; 16];
        for (i, &byte) in self.bytes.iter().enumerate() {
            result[i] = byte as f32 / 255.0;
        }
        result
    }

    /// Get single parameter as normalized float
    pub fn get_float(&self, index: usize) -> f32 {
        self.bytes[index] as f32 / 255.0
    }

    /// Get parameter as angle (0-2π)
    pub fn get_angle(&self, index: usize) -> f32 {
        self.bytes[index] as f32 * 255.0 / 256.0 * std::f32::consts::TAU
    }

    /// Get parameter as integer (0-255)
    pub fn get_int(&self, index: usize) -> u8 {
        self.bytes[index]
    }

    /// Get 4 consecutive parameters as RGBA color
    pub fn get_color(&self, start_index: usize) -> [f32; 4] {
        [
            self.bytes[start_index] as f32 / 255.0,
            self.bytes[start_index + 1] as f32 / 255.0,
            self.bytes[start_index + 2] as f32 / 255.0,
            self.bytes[start_index + 3] as f32 / 255.0,
        ]
    }

    /// Set color at index
    pub fn set_color(&mut self, start_index: usize, rgba: [u8; 4]) {
        self.bytes[start_index..start_index + 4].copy_from_slice(&rgba);
    }
}
```

## Operator Definition

```rust
/// A single operator in the TexGen graph.
#[derive(Debug, Clone)]
pub struct TexgenOperator {
    /// Operator type (determines shader and behavior)
    pub op_type: OperatorType,

    /// Output resolution
    pub resolution: TexgenResolution,

    /// Parameter bytes (interpreted by shader)
    pub params: OperatorParams,

    /// Input operator indices (None = no input for that slot)
    pub inputs: [Option<usize>; 3],

    /// Random seed for procedural variation
    pub seed: u8,

    /// Use HDR texture format (RGBA16Float vs RGBA8Unorm)
    pub hdr: bool,

    /// Keep result cached after evaluation?
    /// - true: Referenced by materials, persist
    /// - false: Intermediate result, can release
    pub needs_render: bool,
}

impl TexgenOperator {
    /// Create a new generator operator (no inputs)
    pub fn generator(op_type: OperatorType, resolution: TexgenResolution) -> Self {
        assert_eq!(op_type.input_count(), 0, "Generator must have 0 inputs");
        Self {
            op_type,
            resolution,
            params: OperatorParams::default(),
            inputs: [None, None, None],
            seed: 0,
            hdr: false,
            needs_render: false,
        }
    }

    /// Create a transform/filter operator (1 input)
    pub fn transform(op_type: OperatorType, resolution: TexgenResolution, input: usize) -> Self {
        assert_eq!(op_type.input_count(), 1, "Transform must have 1 input");
        Self {
            op_type,
            resolution,
            params: OperatorParams::default(),
            inputs: [Some(input), None, None],
            seed: 0,
            hdr: false,
            needs_render: false,
        }
    }

    /// Create a blend operator (2 inputs)
    pub fn blend(op_type: OperatorType, resolution: TexgenResolution, a: usize, b: usize) -> Self {
        assert_eq!(op_type.input_count(), 2, "Blend must have 2 inputs");
        Self {
            op_type,
            resolution,
            params: OperatorParams::default(),
            inputs: [Some(a), Some(b), None],
            seed: 0,
            hdr: false,
            needs_render: false,
        }
    }

    /// Set parameters
    pub fn with_params(mut self, params: OperatorParams) -> Self {
        self.params = params;
        self
    }

    /// Set random seed
    pub fn with_seed(mut self, seed: u8) -> Self {
        self.seed = seed;
        self
    }

    /// Set HDR mode
    pub fn with_hdr(mut self, hdr: bool) -> Self {
        self.hdr = hdr;
        self
    }

    /// Mark as needing persistent render
    pub fn with_needs_render(mut self, needs: bool) -> Self {
        self.needs_render = needs;
        self
    }
}
```

## Complete Graph

```rust
use std::collections::HashMap;

/// A complete TexGen graph with named outputs.
#[derive(Debug, Clone)]
pub struct TexgenGraph {
    /// Name of this texture (for debugging/identification)
    pub name: String,

    /// All operators in topological order (dependencies before dependents)
    pub operators: Vec<TexgenOperator>,

    /// Named outputs mapping to operator indices
    pub outputs: HashMap<String, usize>,

    /// Default resolution for the graph
    pub default_resolution: TexgenResolution,

    /// Use HDR format for output textures
    pub hdr: bool,
}

impl TexgenGraph {
    /// Create a new empty graph
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            operators: Vec::new(),
            outputs: HashMap::new(),
            default_resolution: TexgenResolution::RES_256,
            hdr: false,
        }
    }

    /// Add an operator, returning its index
    pub fn add_operator(&mut self, op: TexgenOperator) -> usize {
        let index = self.operators.len();
        self.operators.push(op);
        index
    }

    /// Register a named output
    pub fn add_output(&mut self, name: impl Into<String>, operator_index: usize) {
        self.outputs.insert(name.into(), operator_index);
    }

    /// Validate the graph structure
    pub fn validate(&self) -> Result<(), String> {
        for (i, op) in self.operators.iter().enumerate() {
            // Check input references
            for input in op.inputs.iter().flatten() {
                if *input >= i {
                    return Err(format!(
                        "Operator {} references future operator {} (forward reference)",
                        i, input
                    ));
                }
            }

            // Check input count matches operator type
            let actual_inputs = op.inputs.iter().filter(|i| i.is_some()).count();
            let expected_inputs = op.op_type.input_count();
            if actual_inputs != expected_inputs {
                return Err(format!(
                    "Operator {} ({:?}) has {} inputs, expected {}",
                    i, op.op_type, actual_inputs, expected_inputs
                ));
            }
        }

        // Check outputs reference valid operators
        for (name, &index) in &self.outputs {
            if index >= self.operators.len() {
                return Err(format!(
                    "Output '{}' references invalid operator index {}",
                    name, index
                ));
            }
        }

        Ok(())
    }

    /// Get operators that need persistent caching (outputs + explicit flags)
    pub fn get_persistent_operators(&self) -> Vec<usize> {
        let mut persistent: Vec<usize> = self.outputs.values().cloned().collect();

        for (i, op) in self.operators.iter().enumerate() {
            if op.needs_render && !persistent.contains(&i) {
                persistent.push(i);
            }
        }

        persistent.sort();
        persistent.dedup();
        persistent
    }
}
```

## GPU Uniform Structures

```rust
use bytemuck::{Pod, Zeroable};

/// Per-operator uniform data uploaded to GPU.
/// Matches constant buffer layout in WGSL shaders.
#[repr(C)]
#[derive(Debug, Copy, Clone, Pod, Zeroable)]
pub struct TexgenUniforms {
    /// Pass metadata: x = pass index, yzw = random values
    pub pass_data: [f32; 4],
    /// Parameters 0-15 (normalized 0-1)
    pub params: [[f32; 4]; 4],
}

impl TexgenUniforms {
    /// Create from operator parameters and pass index
    pub fn new(params: &OperatorParams, pass_index: u32, seed: u8) -> Self {
        // Seed RNG for deterministic random values
        let mut rng = Xorshf96::new(seed as u32);

        Self {
            pass_data: [
                pass_index as f32,
                rng.next_f32(),
                rng.next_f32(),
                rng.next_f32(),
            ],
            params: [
                [params.get_float(0), params.get_float(1), params.get_float(2), params.get_float(3)],
                [params.get_float(4), params.get_float(5), params.get_float(6), params.get_float(7)],
                [params.get_float(8), params.get_float(9), params.get_float(10), params.get_float(11)],
                [params.get_float(12), params.get_float(13), params.get_float(14), params.get_float(15)],
            ],
        }
    }
}

/// Simple xorshift96 PRNG matching Phoenix implementation
pub struct Xorshf96 {
    x: u32,
    y: u32,
    z: u32,
}

impl Xorshf96 {
    pub fn new(seed: u32) -> Self {
        Self {
            x: seed.max(1), // Avoid zero
            y: 362436069,
            z: 521288629,
        }
    }

    pub fn next(&mut self) -> u32 {
        let t = self.x ^ (self.x << 11);
        self.x = self.y;
        self.y = self.z;
        self.z = self.z ^ (self.z >> 19) ^ (t ^ (t >> 8));
        self.z
    }

    pub fn next_f32(&mut self) -> f32 {
        self.next() as f32 / u32::MAX as f32
    }
}
```

## WGSL Struct Definitions

These must match the Rust structs byte-for-byte.

```wgsl
// texgen_common.wgsl

struct TexgenUniforms {
    // x = pass index, yzw = random values
    pass_data: vec4<f32>,
    // Parameters 0-15 as 4 vec4s
    params: array<vec4<f32>, 4>,
}

@group(0) @binding(0) var<uniform> uniforms: TexgenUniforms;
@group(0) @binding(1) var hash_texture: texture_2d<f32>;
@group(0) @binding(2) var linear_sampler: sampler;
@group(0) @binding(3) var input0: texture_2d<f32>;
@group(0) @binding(4) var input1: texture_2d<f32>;

// Helper to access parameters by index
fn get_param(index: u32) -> f32 {
    let vec_idx = index / 4u;
    let comp_idx = index % 4u;
    return uniforms.params[vec_idx][comp_idx];
}

// Sample hash texture with wrapping
fn sample_hash(coord: vec2<f32>) -> vec4<f32> {
    let scaled = coord * 256.0;
    let wrapped = fract(scaled / 256.0) * 256.0;
    return textureSample(hash_texture, linear_sampler, wrapped / 256.0);
}
```

## JSON Parsing

```rust
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// JSON representation of a TexGen graph (for deserialization)
#[derive(Debug, Deserialize)]
pub struct TexgenGraphJson {
    pub name: String,
    pub resolution: ResolutionJson,
    pub hdr: bool,
    pub operators: Vec<OperatorJson>,
    pub outputs: HashMap<String, usize>,
}

#[derive(Debug, Deserialize)]
pub struct ResolutionJson {
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Deserialize)]
pub struct OperatorJson {
    pub filter: String,
    pub resolution: [u32; 2],
    pub seed: u8,
    pub params: serde_json::Value,
    pub inputs: Vec<usize>,
}

impl TexgenGraphJson {
    /// Parse from JSON string
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Convert to internal representation
    pub fn to_graph(&self) -> Result<TexgenGraph, String> {
        let mut graph = TexgenGraph::new(&self.name);
        graph.hdr = self.hdr;
        graph.default_resolution = TexgenResolution::new(
            self.resolution.width,
            self.resolution.height,
        )?;

        for op_json in &self.operators {
            let op_type = parse_operator_type(&op_json.filter)?;
            let resolution = TexgenResolution::new(
                op_json.resolution[0],
                op_json.resolution[1],
            )?;

            let mut inputs = [None; 3];
            for (i, &input) in op_json.inputs.iter().enumerate().take(3) {
                inputs[i] = Some(input);
            }

            let params = parse_params(&op_json.params, op_type)?;

            graph.add_operator(TexgenOperator {
                op_type,
                resolution,
                params,
                inputs,
                seed: op_json.seed,
                hdr: self.hdr,
                needs_render: false,
            });
        }

        for (name, &index) in &self.outputs {
            graph.add_output(name.clone(), index);
            // Mark output operators as needing render
            if index < graph.operators.len() {
                graph.operators[index].needs_render = true;
            }
        }

        graph.validate()?;
        Ok(graph)
    }
}

fn parse_operator_type(filter: &str) -> Result<OperatorType, String> {
    match filter.to_lowercase().as_str() {
        "noise" => Ok(OperatorType::Noise),
        "cells" => Ok(OperatorType::Cells),
        "cells-2" | "cells2" => Ok(OperatorType::Cells2),
        "celledges" | "cell-edges" => Ok(OperatorType::CellEdges),
        "gradient" => Ok(OperatorType::Gradient),
        "rectangle" => Ok(OperatorType::Rectangle),
        "solid-color" | "solidcolor" => Ok(OperatorType::SolidColor),
        "tiles" => Ok(OperatorType::Tiles),
        "sprinkle" => Ok(OperatorType::Sprinkle),
        "subplasma" | "sub-plasma" => Ok(OperatorType::SubPlasma),
        "envmap" | "env-map" => Ok(OperatorType::EnvMap),
        "rotozoom" | "roto-zoom" => Ok(OperatorType::Rotozoom),
        "translate" => Ok(OperatorType::Translate),
        "mirror" => Ok(OperatorType::Mirror),
        "loop" => Ok(OperatorType::Loop),
        "pixelize" => Ok(OperatorType::Pixelize),
        "to-polar" | "topolar" => Ok(OperatorType::ToPolar),
        "colorize" => Ok(OperatorType::Colorize),
        "hsl" => Ok(OperatorType::Hsl),
        "scale" => Ok(OperatorType::Scale),
        "contrast" => Ok(OperatorType::Contrast),
        "invert" => Ok(OperatorType::Invert),
        "curves" => Ok(OperatorType::Curves),
        "combine" => Ok(OperatorType::Combine),
        "mix" => Ok(OperatorType::Mix),
        "mixmap" | "mix-map" => Ok(OperatorType::MixMap),
        "replace-alpha" | "replacealpha" => Ok(OperatorType::ReplaceAlpha),
        "blur" => Ok(OperatorType::Blur),
        "dirblur" | "dir-blur" => Ok(OperatorType::DirBlur),
        "normalmap" | "normal-map" => Ok(OperatorType::Normalmap),
        "turbulence" => Ok(OperatorType::Turbulence),
        "glass" => Ok(OperatorType::Glass),
        "smoothstep" => Ok(OperatorType::Smoothstep),
        "text" => Ok(OperatorType::Text),
        _ => Err(format!("Unknown operator type: {}", filter)),
    }
}

fn parse_params(value: &serde_json::Value, op_type: OperatorType) -> Result<OperatorParams, String> {
    let mut params = OperatorParams::default();

    // Parse based on operator type
    // This would need operator-specific parameter parsing
    // For now, return defaults (real implementation would extract each param)

    Ok(params)
}
```

## Texture Handle

```rust
/// Handle to a texture in the pool.
/// Lightweight index that can be copied freely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TextureHandle(pub(crate) usize);

impl TextureHandle {
    /// Invalid handle sentinel
    pub const INVALID: Self = Self(usize::MAX);

    pub fn is_valid(&self) -> bool {
        self.0 != usize::MAX
    }
}
```

## Related Documents

- [02-graph-evaluation.md](02-graph-evaluation.md) - Evaluation algorithm using these structures
- [03-texture-pool.md](03-texture-pool.md) - TextureHandle and pool management
- [appendix/param-encoding.md](appendix/param-encoding.md) - Parameter interpretation details

## Memory Layout Verification

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_uniform_size() {
        // TexgenUniforms should be 80 bytes (5 × vec4 × 4 bytes)
        assert_eq!(std::mem::size_of::<TexgenUniforms>(), 80);
    }

    #[test]
    fn verify_resolution_packing() {
        let res = TexgenResolution::new(256, 256).unwrap();
        assert_eq!(res.to_packed(), 0x88);

        let res2 = TexgenResolution::from_packed(0x88);
        assert_eq!(res2.width(), 256);
        assert_eq!(res2.height(), 256);

        let res3 = TexgenResolution::from_packed(0xAA);
        assert_eq!(res3.width(), 1024);
        assert_eq!(res3.height(), 1024);
    }

    #[test]
    fn verify_param_normalization() {
        let mut params = OperatorParams::default();
        params.bytes[0] = 128;
        params.bytes[1] = 255;

        assert!((params.get_float(0) - 0.502).abs() < 0.01);
        assert!((params.get_float(1) - 1.0).abs() < 0.01);
    }
}
```
