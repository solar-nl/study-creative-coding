# Texture Pool

This document describes the texture pool system that manages GPU texture allocation and reuse during TexGen graph evaluation.

## Design Goals

1. **Minimize allocations**: Reuse textures when resolution and format match
2. **Efficient lookup**: O(1) access via handles, O(n) search for free textures
3. **Safe lifetime management**: No dangling references
4. **Memory tracking**: Know current and peak usage

## Pool Structure

```rust
use std::sync::Arc;

/// Metadata for a pooled texture
pub struct PooledTexture {
    /// The GPU texture
    pub texture: wgpu::Texture,
    /// Pre-created view for sampling
    pub view: wgpu::TextureView,
    /// Resolution (for matching)
    pub resolution: TexgenResolution,
    /// HDR format flag
    pub hdr: bool,
    /// Currently allocated?
    pub used: bool,
    /// Marked for deletion?
    pub deleted: bool,
}

impl PooledTexture {
    fn new(device: &wgpu::Device, resolution: TexgenResolution, hdr: bool) -> Self {
        let format = if hdr {
            wgpu::TextureFormat::Rgba16Float
        } else {
            wgpu::TextureFormat::Rgba8Unorm
        };

        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("TexGen Pool Texture"),
            size: resolution.extent(),
            mip_level_count: Self::mip_count(resolution),
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING
                 | wgpu::TextureUsages::STORAGE_BINDING
                 | wgpu::TextureUsages::COPY_DST
                 | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });

        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        Self {
            texture,
            view,
            resolution,
            hdr,
            used: false,
            deleted: false,
        }
    }

    fn mip_count(resolution: TexgenResolution) -> u32 {
        let max_dim = resolution.width().max(resolution.height());
        (max_dim as f32).log2().ceil() as u32
    }

    /// Memory usage in bytes
    fn memory_bytes(&self) -> usize {
        let base_size = self.resolution.width() as usize
            * self.resolution.height() as usize
            * if self.hdr { 8 } else { 4 }; // RGBA16F vs RGBA8

        // Include mipmaps (approximately 1.33× base)
        (base_size as f32 * 1.33) as usize
    }
}
```

## Pool Implementation

```rust
pub struct TexturePool {
    device: Arc<wgpu::Device>,
    /// All textures in the pool
    textures: Vec<PooledTexture>,
    /// Memory tracking
    allocated_bytes: usize,
    peak_bytes: usize,
}

impl TexturePool {
    pub fn new(device: Arc<wgpu::Device>) -> Self {
        Self {
            device,
            textures: Vec::new(),
            allocated_bytes: 0,
            peak_bytes: 0,
        }
    }

    /// Allocate a texture from the pool (or create new)
    pub fn allocate(&mut self, resolution: TexgenResolution, hdr: bool) -> TextureHandle {
        // Search for matching unused texture
        for (i, tex) in self.textures.iter_mut().enumerate() {
            if !tex.used && !tex.deleted
                && tex.resolution == resolution
                && tex.hdr == hdr
            {
                tex.used = true;
                self.update_memory_stats();
                return TextureHandle(i);
            }
        }

        // No match: create new texture
        let texture = PooledTexture::new(&self.device, resolution, hdr);
        let bytes = texture.memory_bytes();

        let handle = TextureHandle(self.textures.len());
        self.textures.push(texture);
        self.textures[handle.0].used = true;

        self.allocated_bytes += bytes;
        self.peak_bytes = self.peak_bytes.max(self.allocated_bytes);

        handle
    }

    /// Release a texture back to the pool for reuse
    pub fn release(&mut self, handle: TextureHandle) {
        if handle.is_valid() && handle.0 < self.textures.len() {
            self.textures[handle.0].used = false;
        }
    }

    /// Get texture reference by handle
    pub fn get_texture(&self, handle: TextureHandle) -> &wgpu::Texture {
        assert!(handle.is_valid() && handle.0 < self.textures.len());
        &self.textures[handle.0].texture
    }

    /// Get texture view by handle
    pub fn get_view(&self, handle: TextureHandle) -> &wgpu::TextureView {
        assert!(handle.is_valid() && handle.0 < self.textures.len());
        &self.textures[handle.0].view
    }

    /// Get resolution of texture
    pub fn get_resolution(&self, handle: TextureHandle) -> TexgenResolution {
        assert!(handle.is_valid() && handle.0 < self.textures.len());
        self.textures[handle.0].resolution
    }

    /// Check if texture is HDR
    pub fn is_hdr(&self, handle: TextureHandle) -> bool {
        assert!(handle.is_valid() && handle.0 < self.textures.len());
        self.textures[handle.0].hdr
    }

    /// Clear all cached textures (keeps allocations)
    pub fn clear_cache(&mut self) {
        for tex in &mut self.textures {
            tex.used = false;
        }
    }

    /// Actually deallocate unused textures
    pub fn compact(&mut self) {
        // Mark unused textures for deletion
        for tex in &mut self.textures {
            if !tex.used {
                tex.deleted = true;
            }
        }

        // Remove deleted textures
        self.textures.retain(|t| !t.deleted);

        // Recalculate memory
        self.allocated_bytes = self.textures.iter()
            .filter(|t| t.used)
            .map(|t| t.memory_bytes())
            .sum();
    }

    fn update_memory_stats(&mut self) {
        self.allocated_bytes = self.textures.iter()
            .filter(|t| t.used)
            .map(|t| t.memory_bytes())
            .sum();
        self.peak_bytes = self.peak_bytes.max(self.allocated_bytes);
    }

    /// Current memory usage
    pub fn current_bytes(&self) -> usize {
        self.allocated_bytes
    }

    /// Peak memory usage
    pub fn peak_bytes(&self) -> usize {
        self.peak_bytes
    }

    /// Number of textures in pool
    pub fn texture_count(&self) -> usize {
        self.textures.len()
    }

    /// Number of currently allocated textures
    pub fn allocated_count(&self) -> usize {
        self.textures.iter().filter(|t| t.used).count()
    }
}
```

## Storage Texture View

For compute shader writes, we need storage-compatible views:

```rust
impl TexturePool {
    /// Get a storage texture view for compute shader output
    pub fn get_storage_view(&self, handle: TextureHandle, mip_level: u32) -> wgpu::TextureView {
        let tex = &self.textures[handle.0];
        tex.texture.create_view(&wgpu::TextureViewDescriptor {
            label: Some("TexGen Storage View"),
            format: Some(if tex.hdr {
                wgpu::TextureFormat::Rgba16Float
            } else {
                wgpu::TextureFormat::Rgba8Unorm
            }),
            dimension: Some(wgpu::TextureViewDimension::D2),
            aspect: wgpu::TextureAspect::All,
            base_mip_level: mip_level,
            mip_level_count: Some(1),
            base_array_layer: 0,
            array_layer_count: Some(1),
        })
    }
}
```

## Memory Budget Enforcement

Optional: enforce a maximum memory budget

```rust
impl TexturePool {
    /// Try to allocate within budget, returning None if exceeded
    pub fn allocate_budgeted(
        &mut self,
        resolution: TexgenResolution,
        hdr: bool,
        max_bytes: usize,
    ) -> Option<TextureHandle> {
        // Check if reuse is possible
        for (i, tex) in self.textures.iter_mut().enumerate() {
            if !tex.used && !tex.deleted
                && tex.resolution == resolution
                && tex.hdr == hdr
            {
                tex.used = true;
                self.update_memory_stats();
                return Some(TextureHandle(i));
            }
        }

        // Check if new allocation fits budget
        let new_bytes = {
            let temp = PooledTexture::new(&self.device, resolution, hdr);
            temp.memory_bytes()
        };

        if self.allocated_bytes + new_bytes > max_bytes {
            // Try to free unused textures
            self.compact();

            if self.allocated_bytes + new_bytes > max_bytes {
                return None; // Still over budget
            }
        }

        Some(self.allocate(resolution, hdr))
    }
}
```

## Debug Utilities

```rust
impl TexturePool {
    /// Print pool statistics
    pub fn debug_print(&self) {
        println!("=== Texture Pool ===");
        println!("Total textures: {}", self.textures.len());
        println!("Allocated: {}", self.allocated_count());
        println!("Memory: {} KB (peak: {} KB)",
            self.allocated_bytes / 1024,
            self.peak_bytes / 1024
        );

        println!("\nTextures:");
        for (i, tex) in self.textures.iter().enumerate() {
            println!("  [{}] {}×{} {} {} {}",
                i,
                tex.resolution.width(),
                tex.resolution.height(),
                if tex.hdr { "HDR" } else { "LDR" },
                if tex.used { "USED" } else { "FREE" },
                if tex.deleted { "(DELETED)" } else { "" }
            );
        }
    }

    /// Validate pool integrity
    #[cfg(debug_assertions)]
    pub fn validate(&self) {
        for (i, tex) in self.textures.iter().enumerate() {
            assert!(!tex.deleted || !tex.used,
                "Texture {} is both deleted and used", i);
        }
    }
}
```

## Usage Example

```rust
fn example_evaluation() {
    let device = /* ... */;
    let mut pool = TexturePool::new(device);

    // Allocate textures for a simple graph:
    // Noise → Blur → Colorize

    let noise_tex = pool.allocate(TexgenResolution::RES_512, false);
    // ... render noise ...

    let blur_tex = pool.allocate(TexgenResolution::RES_512, false);
    // ... render blur using noise_tex as input ...

    // Noise is no longer needed
    pool.release(noise_tex);

    let color_tex = pool.allocate(TexgenResolution::RES_512, false);
    // ... render colorize using blur_tex as input ...

    // The released noise_tex slot might be reused for color_tex
    // if resolutions match!

    pool.release(blur_tex);

    // color_tex is the final output - keep it allocated
    println!("Final output at handle: {:?}", color_tex);
    println!("Pool stats: {} textures, {} allocated",
        pool.texture_count(),
        pool.allocated_count()
    );
}
```

## WGSL Texture Sampling

Shaders sample pool textures through bind groups:

```wgsl
@group(0) @binding(2) var input_texture: texture_2d<f32>;
@group(0) @binding(3) var linear_sampler: sampler;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(input_texture);
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    let uv = (vec2<f32>(gid.xy) + 0.5) / vec2<f32>(dims);
    let color = textureSampleLevel(input_texture, linear_sampler, uv, 0.0);

    // ... process color ...
}
```

## Related Documents

- [01-data-structures.md](01-data-structures.md) - TextureHandle definition
- [02-graph-evaluation.md](02-graph-evaluation.md) - How evaluation uses the pool
