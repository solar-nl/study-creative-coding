# nannou: Device Pooling for Creative Coding

> What happens when multiple windows need to share GPU resources?

---

## The Multi-Window Problem

Picture a creative coding setup: a main window showing your visualization, a second window for controls, maybe a third for a different view. Each window needs to render. Each window needs a GPU device.

The naive approach—one device per window—works but wastes resources. GPU devices are heavyweight. Creating them takes time. Buffers and textures can't be shared across devices. If your control window and visualization window could share a device, they could share textures too.

nannou solves this with device pooling. It's a small feature, easily overlooked, but it reveals a pattern worth understanding: using Weak references for automatic cleanup without ownership burden.

---

## Two-Level Pooling

### The Structure

Open `nannou_wgpu/src/device_map.rs` and you'll find a two-tier HashMap:

```rust
pub struct AdapterMap {
    map: Mutex<HashMap<AdapterMapKey, Arc<ActiveAdapter>>>,
}

pub struct DeviceMap {
    map: Mutex<HashMap<DeviceMapKey, Weak<DeviceQueuePair>>>,
}
```

Level one pools physical adapters (GPUs) by power preference. Level two pools logical devices (connections to a GPU) by their configuration.

Why two levels? Because one physical GPU can support multiple logical devices with different feature sets. You might want one device with all features enabled for your main visualization, and a minimal device for a simple preview window.

### The Weak Reference Insight

Notice that `DeviceMap` stores `Weak<DeviceQueuePair>`, not `Arc`. This is the clever part.

Windows hold `Arc<DeviceQueuePair>`—strong references. When you create a window, nannou checks the pool for an existing device with matching configuration. If found, it upgrades the Weak to Arc and returns it. If not found (or if the Weak can't upgrade because all strong references are gone), it creates a new device.

When a window closes, its Arc drops. If that was the last strong reference, the device becomes unreachable. The pool's Weak reference can no longer upgrade. On the next cleanup pass, nannou removes the dead entry.

The pool never prevents cleanup. It only enables sharing while resources are alive.

---

## The Device Lookup Dance

### Getting or Creating a Device

Here's the core logic from `device_map.rs:205-227`:

```rust
pub async fn get_or_request_device_async(
    &self,
    descriptor: wgpu::DeviceDescriptor<'static>,
) -> Arc<DeviceQueuePair> {
    let key = DeviceMapKey { descriptor };
    let mut map = self.device_map.map.lock()
        .expect("failed to acquire lock");

    // Try to reuse an existing device
    if let Some(device_ref) = map.get(&key) {
        if let Some(device) = device_ref.upgrade() {
            return device;  // Existing device still alive, share it
        }
    }

    // No existing device, create a new one
    let (device, queue) = self.adapter
        .request_device(&key.descriptor, None)
        .await
        .expect("could not get or request device");

    let device = Arc::new(DeviceQueuePair { device, queue });
    map.insert(key, Arc::downgrade(&device));  // Store Weak, return Arc
    device
}
```

The flow:
1. Lock the map
2. Try to find an existing device with matching config
3. If found, try to upgrade the Weak to Arc
4. If upgrade succeeds, return the shared device
5. Otherwise, create a new device, store a Weak reference, return Arc

### The Cleanup Pass

At the end of each frame, nannou cleans up dead entries:

```rust
pub fn clear_inactive_devices(&self) {
    let mut map = self.device_map.map.lock()
        .expect("failed to acquire lock");
    map.retain(|_, pair| pair.upgrade().is_some());
}
```

Any Weak that can't upgrade (because all Arcs dropped) gets removed. The pool stays clean without explicit delete calls.

---

## The Key Problem

### Why Custom Hash and Eq?

wgpu's `DeviceDescriptor` doesn't implement `Hash` or `Eq`. HashMap needs both. nannou wraps the descriptor in a newtype with manual implementations:

```rust
pub struct DeviceMapKey {
    descriptor: wgpu::DeviceDescriptor<'static>,
}

impl Hash for DeviceMapKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        hash_device_descriptor(&self.descriptor, state);
    }
}

fn eq_device_descriptor(a: &DeviceDescriptor, b: &DeviceDescriptor) -> bool {
    a.label == b.label && a.features == b.features && a.limits == b.limits
}
```

The comment in the code is telling: "This should be updated as fields are added to the descriptor type." This is a maintenance burden. If wgpu adds a field to `DeviceDescriptor`, nannou's equality check becomes incomplete.

This pattern is common when wrapping types you don't control. It works, but requires vigilance.

---

## What nannou Doesn't Do

Studying what nannou *omits* is as instructive as what it includes.

**No texture caching.** Load an image twice? Two GPU textures. This is fine for creative coding—you rarely load the same image multiple times—but a game engine would want deduplication.

**No buffer pooling.** Every buffer is fresh. No staging belt, no suballocation. Simple, but not optimal for particle systems or dynamic geometry.

**No bind group caching.** Create a new bind group each time you need one. For creative coding's typical complexity, this is fine. For complex scenes, it's wasteful.

nannou optimized for simplicity and rapid iteration, not raw performance. This is appropriate for its audience. But it means Flux, targeting broader use cases, will need patterns nannou doesn't provide.

---

## The DeviceQueuePair Bundle

### Bundling Related Resources

nannou pairs device and queue in one struct:

```rust
pub struct DeviceQueuePair {
    device: wgpu::Device,
    queue: wgpu::Queue,
}
```

This makes sense: you almost always need both. Creating a buffer requires the device. Uploading data requires the queue. Submitting commands requires the queue. Bundling them reduces API surface.

The tradeoff: occasionally you only need one. Device for introspection, queue for a quick upload. But passing the pair is cheap, so the ergonomic benefit outweighs the occasional redundancy.

---

## Row-Padded Buffers: A GPU Alignment Detail

### The Problem

GPU APIs require texture rows to be aligned—often to 256 bytes. Image libraries produce packed data without padding. Upload packed data, and you get garbage textures.

### nannou's Solution

A helper buffer that handles padding:

```rust
pub struct RowPaddedBuffer {
    data: Vec<u8>,
    row_bytes: u32,        // Original row size
    padded_row_bytes: u32, // Aligned row size
}
```

This encapsulates the fiddly alignment math. User code works with logical pixel data; the helper manages the physical layout.

This is the kind of "quality of life" utility creative coding frameworks need. The underlying problem isn't hard, but having a tested solution saves debugging time.

---

## Lessons for Flux

nannou's patterns suggest several approaches:

**Weak references for pools.** If you want sharing without ownership burden, store Weak references. The pool enables sharing while resources live; cleanup happens automatically when they die.

**Bundle related resources.** Device + queue, texture + sampler—if they're always used together, bundle them. API simplicity beats theoretical flexibility.

**Newtype wrappers for Hash/Eq.** When wrapping external types, manual trait implementations are sometimes necessary. Document the maintenance burden.

**Start without caching.** nannou's lack of texture caching and buffer pooling is deliberate simplicity. Start simple; add optimization when profiling shows the need.

**Encapsulate GPU quirks.** Alignment requirements, format conversions, driver workarounds—wrap these in utilities. Don't leak them to user code.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `nannou_wgpu/src/device_map.rs` | 16-47 | AdapterMap and DeviceMap structs |
| `nannou_wgpu/src/device_map.rs` | 205-227 | get_or_request_device_async |
| `nannou_wgpu/src/device_map.rs` | 266-272 | clear_inactive_devices |
| `nannou_wgpu/src/device_map.rs` | 312-332 | Manual Hash/Eq implementations |
| `nannou_wgpu/src/texture/row_padded_buffer.rs` | — | GPU alignment helper |

---

## Related Documents

- [wgpu.md](wgpu.md) — The underlying API nannou builds on
- [rend3.md](rend3.md) — A more aggressive approach to pooling
- [../reclamation-timing.md](../reclamation-timing.md) — When to free resources
