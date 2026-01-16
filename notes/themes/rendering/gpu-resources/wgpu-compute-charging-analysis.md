# wgpu Compute Buffers: Impact on Charging and Shadow Patterns

> How does wgpu's compute model change the CPU-GPU data flow conversation?

---

## The New Dimension: GPU-to-GPU Flow

The [charging vs shadows](charging-vs-shadows.md) analysis focuses on CPU-GPU relationships. But wgpu compute shaders introduce a third flow: **GPU-to-GPU**. A compute shader writes to a storage buffer that a render pass reads—no CPU involved.

This changes the question from "when can the CPU forget?" to "who needs this data, and where do they live?"

```
Traditional (Charging/Shadow):
    CPU ──────────────▶ GPU

With Compute:
    CPU ──────────────▶ GPU ──────────────▶ GPU
           upload           compute→render
                              (no CPU)
```

---

## wgpu's Buffer Model

### Usage Flags Declared Upfront

wgpu requires declaring buffer capabilities at creation:

```rust
let buffer = device.create_buffer(&wgpu::BufferDescriptor {
    label: Some("compute output"),
    size: 1024,
    usage: wgpu::BufferUsages::STORAGE       // Compute shader can read/write
         | wgpu::BufferUsages::COPY_SRC      // Can copy to another buffer
         | wgpu::BufferUsages::COPY_DST,     // Can receive copies
    mapped_at_creation: false,
});
```

This upfront declaration affects both patterns:

| Usage Flag | Charging Implication | Shadow Implication |
|------------|---------------------|-------------------|
| `STORAGE` | Compute-only resources don't need CPU data | Shadow may never be needed |
| `MAP_READ` | Required for download—but can't combine with `STORAGE` | Shadow download needs staging buffer |
| `MAP_WRITE` | Required for upload | Shadow upload needs staging buffer |
| `COPY_SRC/DST` | Enables staging buffer workflow | Bridge between mappable and storage buffers |

### The Mapping Constraint

wgpu buffers with `MAP_READ` or `MAP_WRITE` cannot also have `STORAGE`. This is a WebGPU specification constraint, not a wgpu limitation.

**Consequence**: You cannot directly map a compute shader's output buffer. You must copy to a staging buffer first.

```rust
// This is INVALID:
let bad_buffer = device.create_buffer(&wgpu::BufferDescriptor {
    usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::MAP_READ, // Error!
    // ...
});

// This is correct:
let compute_buffer = device.create_buffer(&wgpu::BufferDescriptor {
    usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
    // ...
});
let staging_buffer = device.create_buffer(&wgpu::BufferDescriptor {
    usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
    // ...
});
```

### Async Mapping Dance

wgpu's mapping is asynchronous:

```rust
// 1. Request mapping
staging_buffer.slice(..).map_async(wgpu::MapMode::Read, |result| {
    // 3. Callback fires when ready
});

// 2. Poll until complete (or use async runtime)
device.poll(wgpu::Maintain::Wait);

// 4. Access mapped data
let data = staging_buffer.slice(..).get_mapped_range();
// 5. When done, must unmap before GPU can use buffer again
drop(data);
staging_buffer.unmap();
```

---

## Impact on the Charging Pattern

### What Changes

Charging assumes a simple flow: CPU generates → uploads → GPU renders → CPU data deleted. With compute, the flow fragments:

```
Classic Charging:
    CPU [vertices] ──charge()──▶ GPU [buffer] ──render──▶ screen
         └── deleted ──┘

Compute Charging:
    CPU [params] ──upload──▶ GPU [uniforms]
                                   │
                                   ▼
    (nothing)            GPU [compute out] ──render──▶ screen
                                   │
                                   │ (CPU never had this data)
                                   ▼
                         What does "charge" mean here?
```

For compute-generated data, there's nothing to charge—the CPU never had it. The charging question becomes: "when can the GPU forget intermediate results?"

### New Charging Questions

1. **Intermediate compute buffers**: A multi-pass compute pipeline produces intermediate results. When can those be reclaimed?

2. **Compute-to-render buffers**: A compute shader generates geometry that a render pass consumes. The render pass "charges" by binding the buffer, but there's no CPU data to free.

3. **Parameter buffers**: Small uniform buffers with compute parameters. These might change every frame (no charging) or be static (charge immediately).

### Adapted Charging for Compute

```rust
enum ComputeBufferLifetime {
    /// Intermediate result, can be freed after dependent passes complete
    Transient { last_consumer_pass: PassId },

    /// Persists across frames, like traditional charged resources
    Persistent,

    /// Changes every frame, never "charged"
    Dynamic,
}

struct ComputeBuffer {
    gpu_buffer: wgpu::Buffer,
    lifetime: ComputeBufferLifetime,
    consumer_count: u32,
    charged_consumers: u32,
}

impl ComputeBuffer {
    fn charge(&mut self, consumer: PassId) {
        self.charged_consumers += 1;

        if let ComputeBufferLifetime::Transient { last_consumer_pass } = self.lifetime {
            if self.charged_consumers == self.consumer_count {
                // All consumers have used this buffer, can be reclaimed
                // (defer actual deletion to avoid mid-frame issues)
            }
        }
    }
}
```

The key insight: **charging in compute pipelines tracks GPU consumers, not CPU references**.

---

## Impact on the Shadow Pattern

### What Changes

Shadows assume CPU access is occasionally needed. But for compute buffers:
- The CPU might need to read results (analysis, saving, feedback loops)
- The CPU might never need access (pure GPU pipeline)
- Access requires a staging buffer dance

### The Staging Buffer as Shadow

In wgpu, the staging buffer effectively IS the shadow:

```rust
struct ComputeBufferShadow {
    /// The actual compute storage buffer (GPU-only)
    storage: wgpu::Buffer,

    /// Staging buffer for CPU access (lazy allocated)
    staging: Option<wgpu::Buffer>,

    /// CPU-side data (lazy allocated, populated on download)
    cpu_data: Option<Vec<u8>>,
}

impl ComputeBufferShadow {
    fn shadow(&mut self, device: &wgpu::Device) -> &mut ShadowAccess {
        // Lazy allocate staging buffer on first access
        if self.staging.is_none() {
            self.staging = Some(device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("shadow staging"),
                size: self.storage.size(),
                usage: wgpu::BufferUsages::MAP_READ
                     | wgpu::BufferUsages::MAP_WRITE
                     | wgpu::BufferUsages::COPY_SRC
                     | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }));
        }
        // ...
    }
}
```

### The Async Download Problem

OpenRNDR's `download()` is synchronous—call it, get data. wgpu's model is inherently async:

```rust
impl ComputeBufferShadow {
    /// Initiates download. Returns a future that resolves when complete.
    async fn download(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) {
        let staging = self.shadow(device);

        // 1. Copy storage → staging (GPU-side)
        let mut encoder = device.create_command_encoder(&Default::default());
        encoder.copy_buffer_to_buffer(&self.storage, 0, staging, 0, self.storage.size());
        queue.submit(Some(encoder.finish()));

        // 2. Map staging buffer (async)
        let (sender, receiver) = futures::channel::oneshot::channel();
        staging.slice(..).map_async(wgpu::MapMode::Read, move |result| {
            sender.send(result).unwrap();
        });

        // 3. Poll until ready
        device.poll(wgpu::Maintain::Wait);
        receiver.await.unwrap().unwrap();

        // 4. Copy to CPU
        {
            let view = staging.slice(..).get_mapped_range();
            self.cpu_data = Some(view.to_vec());
        }
        staging.unmap();
    }
}
```

**Design choice**: Should `download()` be:
- Blocking (poll until complete)—simple but can stall
- Async (return future)—complex but non-blocking
- Split (request + poll + get)—explicit but verbose

### Upload is Simpler

Uploading to a compute buffer is straightforward with `queue.write_buffer()`:

```rust
impl ComputeBufferShadow {
    fn upload(&self, queue: &wgpu::Queue, data: &[u8]) {
        queue.write_buffer(&self.storage, 0, data);
    }
}
```

No staging buffer needed—wgpu handles the copy internally.

---

## Synthesis: A Combined Pattern for wgpu Compute

### Three-Tier Buffer Classification

```rust
enum BufferTier {
    /// Pure GPU: compute-to-compute or compute-to-render
    /// No CPU access, no shadow, potential for charging
    GpuOnly {
        charging: Option<ChargingState>,
    },

    /// CPU-write, GPU-read: uniforms, dynamic parameters
    /// Shadow for write access, no download needed
    CpuToGpu {
        shadow: Option<Vec<u8>>,
    },

    /// Bidirectional: GPU compute results that CPU analyzes
    /// Full shadow with staging buffer
    Bidirectional {
        staging: Option<wgpu::Buffer>,
        cpu_data: Option<Vec<u8>>,
    },
}
```

### Recommended Defaults

| Use Case | Tier | Charging | Shadow |
|----------|------|----------|--------|
| Particle positions (compute-updated, render-consumed) | GpuOnly | No (changes every frame) | None |
| Static geometry from procedural gen | GpuOnly | Yes | None |
| Compute results for CPU analysis | Bidirectional | No | Lazy staging |
| Per-frame uniforms | CpuToGpu | No | Direct write |
| Baked compute lookup tables | GpuOnly | Yes | None |

### API Sketch

```rust
pub struct ComputeBuffer {
    inner: wgpu::Buffer,
    tier: BufferTier,
    size: u64,
}

impl ComputeBuffer {
    /// Create a GPU-only compute buffer
    pub fn gpu_only(device: &wgpu::Device, size: u64, chargeable: bool) -> Self {
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size,
            usage: wgpu::BufferUsages::STORAGE
                 | wgpu::BufferUsages::COPY_SRC
                 | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self {
            inner: buffer,
            tier: BufferTier::GpuOnly {
                charging: if chargeable { Some(ChargingState::new()) } else { None },
            },
            size,
        }
    }

    /// Create a bidirectional buffer with potential CPU readback
    pub fn bidirectional(device: &wgpu::Device, size: u64) -> Self {
        // Same creation, different tier tracking
        Self {
            tier: BufferTier::Bidirectional {
                staging: None,  // Lazy
                cpu_data: None,
            },
            // ...
        }
    }

    /// Download compute results to CPU (async)
    pub async fn download(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) -> Result<&[u8], Error> {
        match &mut self.tier {
            BufferTier::Bidirectional { staging, cpu_data } => {
                // Lazy allocate staging
                let stg = staging.get_or_insert_with(|| {
                    device.create_buffer(&wgpu::BufferDescriptor {
                        size: self.size,
                        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
                        // ...
                    })
                });

                // Copy + map + read dance
                // ...

                Ok(cpu_data.as_ref().unwrap())
            }
            _ => Err(Error::NotBidirectional),
        }
    }

    /// Mark that a consumer has finished using this buffer (charging)
    pub fn charge(&mut self) {
        if let BufferTier::GpuOnly { charging: Some(state) } = &mut self.tier {
            state.charge();
        }
    }
}
```

---

## Key Takeaways

### For Charging

1. **Compute buffers often have nothing to charge**—data originates on GPU
2. **Charging becomes consumer-tracking**—when have all GPU passes consumed this?
3. **Transient intermediates are the new target**—multi-pass pipelines create temporary buffers
4. **Frame-delayed deletion still applies**—in-flight frames might reference "charged" buffers

### For Shadows

1. **Staging buffers are mandatory for readback**—`STORAGE` and `MAP_READ` are mutually exclusive
2. **Lazy staging allocation preserves the shadow philosophy**—most compute buffers never need CPU access
3. **Async mapping changes the API surface**—blocking `download()` has hidden costs
4. **Upload is simpler**—`queue.write_buffer()` handles it without staging

### The Bigger Picture

wgpu's compute model expands the CPU-GPU relationship into a triangle:

```
        CPU
       ↗   ↖
  upload   download
     ↓       ↑
    GPU ────▶ GPU
      compute passes
```

The charging pattern adapts to track GPU-to-GPU dependencies. The shadow pattern adapts to handle async staging. Both remain useful, but the "data lives somewhere" model becomes "data flows through a pipeline."

---

## Related Documents

- [charging-vs-shadows.md](charging-vs-shadows.md) — Original pattern comparison
- [wgpu.md](per-framework/wgpu.md) — wgpu resource handling deep dive
- [reclamation-timing.md](reclamation-timing.md) — When to free GPU resources
- [allocation-strategies.md](allocation-strategies.md) — Buffer allocation patterns
