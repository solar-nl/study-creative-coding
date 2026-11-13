# Graph Evaluation

This document describes the algorithm for evaluating TexGen operator graphs, including topological sorting, memoization, multi-pass handling, and resource management.

## Evaluation Overview

TexGen evaluates operator graphs through **recursive descent with memoization**:

```
Request Output Texture "albedo"
    │
    ├─ Lookup output operator index
    │
    └─ evaluate(operator_index)
         │
         ├─ Cache hit? → Return cached texture
         │
         ├─ Recursively evaluate all inputs
         │   ├─ evaluate(input[0])
         │   ├─ evaluate(input[1])
         │   └─ evaluate(input[2])
         │
         ├─ Allocate render targets
         │   ├─ result = pool.allocate(resolution, hdr)
         │   └─ backbuffer = pool.allocate(resolution, hdr)
         │
         ├─ Execute shader passes
         │   └─ for pass in 0..pass_count:
         │        ├─ Swap result ↔ backbuffer
         │        ├─ Bind textures
         │        ├─ Upload uniforms
         │        └─ Dispatch compute/draw
         │
         ├─ Generate mipmaps
         │
         ├─ Release backbuffer
         │
         ├─ Conditionally release input textures
         │
         └─ Cache and return result
```

## Evaluator Structure

```rust
use std::collections::HashMap;

pub struct TexgenEvaluator {
    /// GPU device handle
    device: Arc<wgpu::Device>,
    /// GPU queue handle
    queue: Arc<wgpu::Queue>,

    /// Texture pool for allocation/reuse
    pool: TexturePool,

    /// Cached results per operator (texture handles)
    cache: HashMap<usize, TextureHandle>,

    /// Hash texture (256×256 random values)
    hash_texture: wgpu::Texture,
    hash_view: wgpu::TextureView,

    /// Compute pipelines per operator type
    pipelines: HashMap<OperatorType, wgpu::ComputePipeline>,

    /// Uniform buffer (reused per dispatch)
    uniform_buffer: wgpu::Buffer,

    /// Bind group layouts
    generator_layout: wgpu::BindGroupLayout,
    transform_layout: wgpu::BindGroupLayout,
    blend_layout: wgpu::BindGroupLayout,
}

impl TexgenEvaluator {
    pub fn new(device: Arc<wgpu::Device>, queue: Arc<wgpu::Queue>) -> Self {
        let pool = TexturePool::new(device.clone());

        // Create hash texture
        let (hash_texture, hash_view) = create_hash_texture(&device, &queue);

        // Create uniform buffer
        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("TexGen Uniform Buffer"),
            size: std::mem::size_of::<TexgenUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Create bind group layouts
        let generator_layout = create_generator_bind_group_layout(&device);
        let transform_layout = create_transform_bind_group_layout(&device);
        let blend_layout = create_blend_bind_group_layout(&device);

        // Load pipelines lazily (could also pre-create all)
        let pipelines = HashMap::new();

        Self {
            device,
            queue,
            pool,
            cache: HashMap::new(),
            hash_texture,
            hash_view,
            pipelines,
            uniform_buffer,
            generator_layout,
            transform_layout,
            blend_layout,
        }
    }

    /// Evaluate a graph and return handles to all output textures
    pub fn evaluate(&mut self, graph: &TexgenGraph) -> HashMap<String, TextureHandle> {
        // Clear cache from previous evaluation
        self.cache.clear();

        // Mark output operators as needing render
        let persistent = graph.get_persistent_operators();

        // Evaluate each output
        let mut results = HashMap::new();
        for (name, &index) in &graph.outputs {
            let handle = self.evaluate_operator(graph, index, &persistent);
            results.insert(name.clone(), handle);
        }

        results
    }

    /// Evaluate a single operator, recursively evaluating dependencies
    fn evaluate_operator(
        &mut self,
        graph: &TexgenGraph,
        index: usize,
        persistent: &[usize],
    ) -> TextureHandle {
        // Check cache
        if let Some(&handle) = self.cache.get(&index) {
            return handle;
        }

        let op = &graph.operators[index];

        // Recursively evaluate inputs
        let mut input_handles = [TextureHandle::INVALID; 3];
        for (i, &input_opt) in op.inputs.iter().enumerate() {
            if let Some(input_index) = input_opt {
                input_handles[i] = self.evaluate_operator(graph, input_index, persistent);
            }
        }

        // Allocate render targets
        let result = self.pool.allocate(op.resolution, op.hdr);
        let backbuffer = if op.op_type.pass_count() > 1 {
            self.pool.allocate(op.resolution, op.hdr)
        } else {
            TextureHandle::INVALID
        };

        // Execute shader
        self.execute_operator(op, result, backbuffer, input_handles);

        // Generate mipmaps
        self.generate_mipmaps(result);

        // Release backbuffer
        if backbuffer.is_valid() {
            self.pool.release(backbuffer);
        }

        // Release input textures if not persistent
        for (i, &input_opt) in op.inputs.iter().enumerate() {
            if let Some(input_index) = input_opt {
                if !persistent.contains(&input_index) {
                    self.pool.release(input_handles[i]);
                }
            }
        }

        // Cache result
        self.cache.insert(index, result);

        result
    }
}
```

## Multi-Pass Execution

Multi-pass operators (Noise, Blur, Cells) ping-pong between two textures:

```rust
impl TexgenEvaluator {
    fn execute_operator(
        &mut self,
        op: &TexgenOperator,
        mut result: TextureHandle,
        mut backbuffer: TextureHandle,
        inputs: [TextureHandle; 3],
    ) {
        let pass_count = op.op_type.pass_count();

        // Create command encoder
        let mut encoder = self.device.create_command_encoder(
            &wgpu::CommandEncoderDescriptor {
                label: Some("TexGen Operator"),
            }
        );

        for pass in 0..pass_count {
            // Swap targets for ping-pong
            if pass > 0 {
                std::mem::swap(&mut result, &mut backbuffer);
            }

            // Determine input texture for this pass
            let source = if pass == 0 {
                // First pass: use parent input
                inputs[0]
            } else {
                // Subsequent passes: use previous result
                backbuffer
            };

            // Create uniforms for this pass
            let uniforms = TexgenUniforms::new(&op.params, pass as u32, op.seed);
            self.queue.write_buffer(
                &self.uniform_buffer,
                0,
                bytemuck::bytes_of(&uniforms),
            );

            // Create bind group
            let bind_group = self.create_bind_group(op, source, inputs[1], inputs[2]);

            // Get or create pipeline
            let pipeline = self.get_or_create_pipeline(op.op_type);

            // Dispatch compute shader
            {
                let mut pass = encoder.begin_compute_pass(
                    &wgpu::ComputePassDescriptor {
                        label: Some("TexGen Pass"),
                        timestamp_writes: None,
                    }
                );

                pass.set_pipeline(pipeline);
                pass.set_bind_group(0, &bind_group, &[]);

                // Dispatch workgroups (8×8 threads per group)
                let workgroups_x = (op.resolution.width() + 7) / 8;
                let workgroups_y = (op.resolution.height() + 7) / 8;
                pass.dispatch_workgroups(workgroups_x, workgroups_y, 1);
            }
        }

        // Submit commands
        self.queue.submit(std::iter::once(encoder.finish()));
    }
}
```

## Bind Group Creation

Different operator types need different bind group layouts:

```rust
impl TexgenEvaluator {
    fn create_bind_group(
        &self,
        op: &TexgenOperator,
        input0: TextureHandle,
        input1: TextureHandle,
        input2: TextureHandle,
    ) -> wgpu::BindGroup {
        let input_count = op.op_type.input_count();
        let needs_hash = op.op_type.needs_hash();

        let result_view = self.pool.get_view(result);

        match input_count {
            0 => {
                // Generator: uniforms + hash + output
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("Generator Bind Group"),
                    layout: &self.generator_layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: self.uniform_buffer.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(&self.hash_view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: wgpu::BindingResource::TextureView(result_view),
                        },
                    ],
                })
            }
            1 => {
                // Transform: uniforms + hash + input + output
                let input_view = self.pool.get_view(input0);
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("Transform Bind Group"),
                    layout: &self.transform_layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: self.uniform_buffer.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(
                                if needs_hash { &self.hash_view } else { input_view }
                            ),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: wgpu::BindingResource::TextureView(input_view),
                        },
                        wgpu::BindGroupEntry {
                            binding: 3,
                            resource: wgpu::BindingResource::TextureView(result_view),
                        },
                    ],
                })
            }
            2 => {
                // Blend: uniforms + input0 + input1 + output
                let view0 = self.pool.get_view(input0);
                let view1 = self.pool.get_view(input1);
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("Blend Bind Group"),
                    layout: &self.blend_layout,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: self.uniform_buffer.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(view0),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: wgpu::BindingResource::TextureView(view1),
                        },
                        wgpu::BindGroupEntry {
                            binding: 3,
                            resource: wgpu::BindingResource::TextureView(result_view),
                        },
                    ],
                })
            }
            _ => panic!("Invalid input count"),
        }
    }
}
```

## Bind Group Layouts

```rust
fn create_generator_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("TexGen Generator Layout"),
        entries: &[
            // Uniforms
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: Some(
                        std::num::NonZeroU64::new(
                            std::mem::size_of::<TexgenUniforms>() as u64
                        ).unwrap()
                    ),
                },
                count: None,
            },
            // Hash texture (read)
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Sampler
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            // Output texture (write)
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: wgpu::TextureFormat::Rgba16Float,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            },
        ],
    })
}

fn create_transform_bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("TexGen Transform Layout"),
        entries: &[
            // Uniforms
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: Some(
                        std::num::NonZeroU64::new(
                            std::mem::size_of::<TexgenUniforms>() as u64
                        ).unwrap()
                    ),
                },
                count: None,
            },
            // Hash texture (optional, for some ops)
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            // Input texture
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::COMPUTE,
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
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
            // Output texture (write)
            wgpu::BindGroupLayoutEntry {
                binding: 4,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::StorageTexture {
                    access: wgpu::StorageTextureAccess::WriteOnly,
                    format: wgpu::TextureFormat::Rgba16Float,
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            },
        ],
    })
}
```

## Hash Texture Generation

The hash texture provides deterministic random values for noise generation:

```rust
fn create_hash_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
) -> (wgpu::Texture, wgpu::TextureView) {
    const SIZE: u32 = 256;

    // Generate random data using xorshf96
    let mut rng = Xorshf96::new(12345);
    let mut data = vec![0u8; (SIZE * SIZE * 4) as usize];

    for pixel in data.chunks_exact_mut(4) {
        pixel[0] = (rng.next() & 0xFF) as u8;
        pixel[1] = (rng.next() & 0xFF) as u8;
        pixel[2] = (rng.next() & 0xFF) as u8;
        pixel[3] = (rng.next() & 0xFF) as u8;
    }

    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("TexGen Hash Texture"),
        size: wgpu::Extent3d {
            width: SIZE,
            height: SIZE,
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
        &data,
        wgpu::ImageDataLayout {
            offset: 0,
            bytes_per_row: Some(SIZE * 4),
            rows_per_image: Some(SIZE),
        },
        wgpu::Extent3d {
            width: SIZE,
            height: SIZE,
            depth_or_array_layers: 1,
        },
    );

    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

    (texture, view)
}
```

## Mipmap Generation

After operator execution, generate mipmaps for proper texture filtering:

```rust
impl TexgenEvaluator {
    fn generate_mipmaps(&self, handle: TextureHandle) {
        let texture = self.pool.get_texture(handle);

        // WGPU doesn't have built-in mipmap generation
        // Options:
        // 1. Use wgpu-mipmap crate
        // 2. Implement blit-based mipmap generation
        // 3. Use compute shader for each mip level

        // Example using blit approach:
        let mip_count = (texture.width().max(texture.height()) as f32).log2().ceil() as u32;

        let mut encoder = self.device.create_command_encoder(
            &wgpu::CommandEncoderDescriptor {
                label: Some("Mipmap Generation"),
            }
        );

        for mip in 1..mip_count {
            // Create views for source and destination mip levels
            let src_view = texture.create_view(&wgpu::TextureViewDescriptor {
                base_mip_level: mip - 1,
                mip_level_count: Some(1),
                ..Default::default()
            });

            let dst_view = texture.create_view(&wgpu::TextureViewDescriptor {
                base_mip_level: mip,
                mip_level_count: Some(1),
                ..Default::default()
            });

            // Render source mip to destination mip with bilinear filtering
            // (Implementation would use a blit shader)
        }

        self.queue.submit(std::iter::once(encoder.finish()));
    }
}
```

## Topological Sort (Alternative Approach)

For non-recursive evaluation, pre-sort operators:

```rust
impl TexgenGraph {
    /// Return operators in evaluation order (dependencies before dependents)
    pub fn topological_order(&self) -> Vec<usize> {
        let mut visited = vec![false; self.operators.len()];
        let mut order = Vec::with_capacity(self.operators.len());

        fn visit(
            graph: &TexgenGraph,
            index: usize,
            visited: &mut [bool],
            order: &mut Vec<usize>,
        ) {
            if visited[index] {
                return;
            }
            visited[index] = true;

            // Visit dependencies first
            for input in graph.operators[index].inputs.iter().flatten() {
                visit(graph, *input, visited, order);
            }

            order.push(index);
        }

        // Visit all output operators (and their dependencies)
        for &output_index in self.outputs.values() {
            visit(self, output_index, &mut visited, &mut order);
        }

        order
    }
}

impl TexgenEvaluator {
    /// Non-recursive evaluation using pre-sorted order
    pub fn evaluate_sorted(&mut self, graph: &TexgenGraph) -> HashMap<String, TextureHandle> {
        self.cache.clear();

        let order = graph.topological_order();
        let persistent = graph.get_persistent_operators();

        // Evaluate in dependency order
        for &index in &order {
            if self.cache.contains_key(&index) {
                continue;
            }

            let op = &graph.operators[index];

            // Get input handles (guaranteed to be cached)
            let mut inputs = [TextureHandle::INVALID; 3];
            for (i, &input_opt) in op.inputs.iter().enumerate() {
                if let Some(input_index) = input_opt {
                    inputs[i] = self.cache[&input_index];
                }
            }

            // Allocate and execute
            let result = self.pool.allocate(op.resolution, op.hdr);
            let backbuffer = if op.op_type.pass_count() > 1 {
                self.pool.allocate(op.resolution, op.hdr)
            } else {
                TextureHandle::INVALID
            };

            self.execute_operator(op, result, backbuffer, inputs);
            self.generate_mipmaps(result);

            if backbuffer.is_valid() {
                self.pool.release(backbuffer);
            }

            // Release non-persistent inputs
            for (i, &input_opt) in op.inputs.iter().enumerate() {
                if let Some(input_index) = input_opt {
                    if !persistent.contains(&input_index) {
                        // Check if any remaining operators need this input
                        let still_needed = order[order.iter().position(|&x| x == index).unwrap()..]
                            .iter()
                            .any(|&later| {
                                graph.operators[later].inputs.iter().flatten().any(|&i| i == input_index)
                            });

                        if !still_needed {
                            self.pool.release(inputs[i]);
                        }
                    }
                }
            }

            self.cache.insert(index, result);
        }

        // Collect outputs
        graph.outputs.iter()
            .map(|(name, &index)| (name.clone(), self.cache[&index]))
            .collect()
    }
}
```

## Related Documents

- [01-data-structures.md](01-data-structures.md) - Data types used here
- [03-texture-pool.md](03-texture-pool.md) - Pool allocation/release
- [04-generators.md](04-generators.md) - Generator shader implementations
