# nannou_wgpu: Device Pooling for Creative Coding

> How nannou manages GPU resources across multiple windows

---

## Overview

nannou_wgpu is a thin wrapper over wgpu designed for creative coding applications. Its primary contribution to resource management is **device pooling** - sharing GPU devices across multiple windows to enable resource sharing and reduce overhead.

The key insight: **use `Weak` references for automatic cleanup when resources are no longer needed**. When a window closes, its device reference drops, and if no other windows share that device, the device is automatically removed from the pool.

---

## Device Pooling: Two-Level HashMap

### The Problem

A creative coding application might have multiple windows - perhaps one for the main visualization and another for controls or secondary views. Each window needs a GPU device. Without pooling:

- Each window creates its own device (wasteful)
- Resources can't be shared between windows
- Synchronization becomes more complex

### nannou's Solution

nannou uses a two-level HashMap structure:

```rust
// From nannou_wgpu/src/device_map.rs:16-19, 44-47
pub struct AdapterMap {
    map: Mutex<HashMap<AdapterMapKey, Arc<ActiveAdapter>>>,
}

pub struct DeviceMap {
    map: Mutex<HashMap<DeviceMapKey, Weak<DeviceQueuePair>>>,
}
```

Level 1: `AdapterMap` pools physical GPU adapters by power preference
Level 2: `DeviceMap` pools logical devices by their descriptor

### The Weak Reference Pattern

The crucial detail is in `DeviceMap` - it stores `Weak<DeviceQueuePair>`, not `Arc`:

```rust
// From device_map.rs:205-227
pub async fn get_or_request_device_async(
    &self,
    descriptor: wgpu::DeviceDescriptor<'static>,
) -> Arc<DeviceQueuePair> {
    let key = DeviceMapKey { descriptor };
    let mut map = self.device_map.map.lock()
        .expect("failed to acquire lock");

    // Try to upgrade existing weak reference
    if let Some(device_ref) = map.get(&key) {
        if let Some(device) = device_ref.upgrade() {
            return device;  // Reuse existing device
        }
    }

    // Create new device
    let (device, queue) = self.adapter
        .request_device(&key.descriptor, None)
        .await
        .expect("could not get or request device");

    let device = Arc::new(DeviceQueuePair { device, queue });
    map.insert(key, Arc::downgrade(&device));  // Store weak reference
    device
}
```

### Why Weak Works Here

1. Windows hold `Arc<DeviceQueuePair>` - strong references
2. Pool holds `Weak<DeviceQueuePair>` - doesn't prevent cleanup
3. When all windows close, the `Arc` drops, device is freed
4. Next lookup sees `Weak::upgrade()` returns `None`, creates new device

### Cleanup Logic

nannou cleans up at the end of each frame:

```rust
// From device_map.rs:147-159
pub fn clear_inactive_adapters_and_devices(&self) {
    let mut map = self.map.lock()
        .expect("failed to acquire lock");

    map.retain(|_, adapter| {
        adapter.clear_inactive_devices();
        adapter.device_count() > 0
    });
}

// From device_map.rs:266-272
pub fn clear_inactive_devices(&self) {
    let mut map = self.device_map.map.lock()
        .expect("failed to acquire lock");

    map.retain(|_, pair| pair.upgrade().is_some());
}
```

---

## Map Key Design

### The Problem

`wgpu::DeviceDescriptor` doesn't implement `Hash` or `Eq`. nannou needs these for HashMap keys.

### The Solution

Wrapper types with manual implementations:

```rust
// From device_map.rs:53-56
pub struct DeviceMapKey {
    descriptor: wgpu::DeviceDescriptor<'static>,
}

// From device_map.rs:312-324
impl Hash for DeviceMapKey {
    fn hash<H: Hasher>(&self, state: &mut H) {
        hash_device_descriptor(&self.descriptor, state);
    }
}

impl PartialEq for DeviceMapKey {
    fn eq(&self, other: &Self) -> bool {
        eq_device_descriptor(&self.descriptor, &other.descriptor)
    }
}

// From device_map.rs:327-332
fn eq_device_descriptor(a: &DeviceDescriptor, b: &DeviceDescriptor) -> bool {
    a.label == b.label && a.features == b.features && a.limits == b.limits
}
```

Note the comment: "This should be updated as fields are added to the descriptor type." This is a maintenance burden - if wgpu adds fields, nannou must update these functions.

### Flux Implications

For Flux's resource caching:
- **Consider typed wrapper keys** - newtype pattern for HashMap compatibility
- **Document maintenance requirements** - upstream changes may require updates
- **Derive when possible** - but wgpu types don't always support this

---

## DeviceQueuePair: Unified Handle

### The Pattern

nannou bundles device and queue together:

```rust
// From device_map.rs:59-63
pub struct DeviceQueuePair {
    device: wgpu::Device,
    queue: wgpu::Queue,
}

impl DeviceQueuePair {
    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }
}
```

This makes sense for nannou's use case - you always need both to do anything useful, and they share a lifetime.

### Flux Implications

Consider whether to bundle:
- **Pro**: Single handle simplifies API
- **Con**: Sometimes you only need device (for creation)
- **Flux decision**: Likely bundle in the resource pool context

---

## What nannou Doesn't Do

Studying what nannou *doesn't* implement is as instructive as what it does:

### No Texture Caching

nannou doesn't cache textures. Each `Texture::from_path()` creates a new GPU texture. This is fine for creative coding where texture reuse is rare, but not ideal for a game engine.

### No Buffer Pooling

Buffers are created fresh each time. There's no staging belt or buffer suballocation. Again, appropriate for creative coding where per-frame allocations are acceptable.

### No Bind Group Caching

nannou has a `BindGroupBuilder` helper, but it creates new bind groups each time. No deduplication.

### Flux Implications

nannou's minimalism is intentional - it serves creative coding where simplicity trumps optimization. Flux may need:
- **Texture caching** - if the same image is loaded multiple times
- **Buffer pooling** - for frequently updated geometry
- **Bind group deduplication** - if bind groups are recreated per-frame

---

## Row-Padded Buffer: GPU Alignment

### The Problem

When uploading texture data, GPU APIs require rows to be aligned to specific byte boundaries (often 256 bytes). Image libraries produce packed data without padding.

### nannou's Solution

A helper buffer that handles padding:

```rust
// From nannou_wgpu/src/texture/row_padded_buffer.rs (structure)
pub struct RowPaddedBuffer {
    data: Vec<u8>,
    row_bytes: u32,
    padded_row_bytes: u32,
}
```

This encapsulates the padding math that would otherwise be scattered through texture upload code.

### Flux Implications

For Flux's texture uploads:
- **Encapsulate alignment requirements** - don't leak padding to user code
- **Consider format-aware helpers** - different formats have different alignment needs

---

## Threading: Per-Adapter Polling

### The Pattern

nannou can poll all devices across all adapters:

```rust
// From device_map.rs:161-170
pub(crate) fn _poll_all_devices(&self, maintain: wgpu::Maintain) {
    let map = self.map.lock()
        .expect("failed to acquire lock");

    for adapter in map.values() {
        adapter._poll_all_devices(maintain.clone());
    }
}

// From device_map.rs:276-287
fn _poll_all_devices(&self, maintain: wgpu::Maintain) {
    let map = self.device_map.map.lock()
        .expect("failed to acquire lock");

    for weak in map.values() {
        if let Some(pair) = weak.upgrade() {
            pair.device().poll(maintain.clone());
        }
    }
}
```

Note the `_` prefix - this is internal API, suggesting nannou handles polling automatically so users don't have to think about it.

### Flux Implications

For Flux's polling:
- **Automatic polling** - hide this from users when possible
- **Centralized control** - poll from one place, not scattered

---

## Summary: Key Patterns for Flux

| Pattern | nannou Approach | Flux Application |
|---------|-----------------|------------------|
| **Device sharing** | Two-level HashMap | Consider for multi-window support |
| **Automatic cleanup** | Weak references | Use for pool entries that should auto-cleanup |
| **Key types** | Manual Hash/Eq impl | Derive when possible, document when not |
| **Device+Queue bundling** | Single struct | Bundle in resource context |
| **Texture caching** | None | Add if reuse is common |
| **Buffer pooling** | None | Add for dynamic geometry |
| **Row padding** | Helper struct | Encapsulate alignment |

---

## Design Insight: Simplicity vs Optimization

nannou's device pooling is its most sophisticated resource management feature, and it's relatively simple. This reflects nannou's design philosophy: creative coding values simplicity and rapid iteration over maximum performance.

For Flux, the question is where on this spectrum to land. The device pooling pattern is worth adopting. The lack of texture/buffer caching might be fine initially but could become a bottleneck for complex applications.

`★ Insight ─────────────────────────────────────`
nannou's `Weak` reference pattern for device pooling is elegant: the pool doesn't keep resources alive, but it does allow sharing while resources exist. This inverts the typical cache pattern where the cache owns entries.
`─────────────────────────────────────────────────`

---

## Source Files

| File | Purpose |
|------|---------|
| `nannou_wgpu/src/device_map.rs:16-47` | AdapterMap and DeviceMap definitions |
| `nannou_wgpu/src/device_map.rs:205-227` | get_or_request_device_async with Weak upgrade |
| `nannou_wgpu/src/device_map.rs:266-272` | Cleanup via retain + upgrade |
| `nannou_wgpu/src/device_map.rs:312-332` | Manual Hash/Eq implementations |
| `nannou_wgpu/src/texture/row_padded_buffer.rs` | GPU alignment helper |

---

## Related Documents

- [wgpu.md](wgpu.md) - The underlying API
- [rend3.md](rend3.md) - More aggressive pooling
- [../reclamation-timing.md](../reclamation-timing.md) - When to free resources
