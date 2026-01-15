# Reclamation Timing: When Memory Returns

> You're done with a buffer. When can the GPU actually reuse that memory?

---

## The Asynchrony Problem

CPU and GPU operate on different timelines. When your code drops a buffer handle, the CPU has moved on. But the GPU might still be executing commands that reference that buffer—commands you submitted frames ago that are still working through the queue.

Free the memory while the GPU is reading from it, and you get corruption. Wait too long to free, and memory pressure builds. The timing of reclamation is a balancing act between safety and efficiency.

The question guiding this exploration: *when is it safe to free GPU memory, and how do frameworks ensure safety?*

---

## Immediate Drop: Let the Backend Handle It

wgpu's default approach looks simple from the user's perspective:

```rust
{
    let buffer = device.create_buffer(&desc);
    // ... use buffer ...
}  // Buffer dropped here
```

Drop the handle, and the resource is "freed." But internally, wgpu doesn't immediately reclaim the memory. It schedules cleanup, then waits until `device.poll()` confirms no in-flight commands reference the resource.

This is the magic of modern safe graphics APIs: the user-facing model is simple (drop when done), but the implementation handles the complexity (wait until actually safe).

The limitation is that memory doesn't immediately become available. If you're churning through temporary buffers—creating and dropping many per frame—they accumulate until the next poll. For most applications, this is fine. For memory-constrained scenarios, it might not be.

---

## Explicit Destroy: Taking Control

wgpu offers an escape hatch:

```rust
buffer.destroy();  // Mark for immediate destruction
// Further use will error
```

`destroy()` marks the resource for aggressive cleanup. The memory may become available sooner than waiting for the drop to naturally schedule cleanup.

The cost is responsibility. After calling `destroy()`, using the buffer produces errors. You've taken manual control; you must ensure nothing else uses it.

This pattern is useful when you know a resource's lifetime precisely—loading screens, level transitions, explicit cleanup phases. For dynamic resource management, it's error-prone.

---

## Frame-Delayed Deletion: The Safe Middle Ground

rend3 queues deletions for processing at frame boundaries:

```rust
pub struct ResourcePool {
    pending_deletes: Vec<ResourceId>,
    delete_delay_frames: usize,  // Default: 2
    frame_delete_queues: VecDeque<Vec<ResourceId>>,
}

impl ResourcePool {
    pub fn mark_for_delete(&mut self, id: ResourceId) {
        self.pending_deletes.push(id);
    }

    pub fn process_frame_end(&mut self) {
        // Queue current frame's deletes
        let this_frame = std::mem::take(&mut self.pending_deletes);
        self.frame_delete_queues.push_back(this_frame);

        // Process deletes from N frames ago (safe now)
        if self.frame_delete_queues.len() > self.delete_delay_frames {
            let safe_to_delete = self.frame_delete_queues.pop_front().unwrap();
            for id in safe_to_delete {
                self.actually_delete(id);
            }
        }
    }
}
```

Deletion is deferred by a fixed number of frames. A resource marked for deletion in frame N actually frees in frame N+2 (with the default delay of 2). This ensures any in-flight commands from frames N and N+1 have completed before the memory is reclaimed.

The delay handles double-buffering naturally. Frame N's commands might still be executing when frame N+1 starts. A 2-frame delay guarantees the commands have finished.

This is deterministic and predictable. You know exactly when resources free. The cost is that memory lingers slightly longer than necessary—but "slightly longer" is usually measured in milliseconds.

---

## Session-Based Cleanup: Grouping by Lifetime

OpenRNDR groups resources into sessions:

```kotlin
class Session {
    val colorBuffers = mutableSetOf<ColorBuffer>()
    val vertexBuffers = mutableSetOf<VertexBuffer>()
    // ...

    fun end() {
        colorBuffers.forEach { it.destroy() }
        colorBuffers.clear()
        // ...
    }
}
```

When you create a resource, it registers with the current session. When the session ends, all its resources clean up together.

This maps naturally to application structure. A scene session contains scene resources. A frame session contains per-frame temporaries. An effect session contains effect-specific buffers. End the session, and everything goes away—no manual tracking, no individual cleanup calls.

Sessions can nest. The root session lives for the application's lifetime. Child sessions live for scenes or effects. Ending a parent cascades to children.

The pattern shines at boundaries: level transitions, effect completion, application shutdown. It's less suited for individual resource management—you'd need very granular sessions.

---

## Weak Reference Pools: Automatic Cleanup

nannou's device pool stores `Weak` references:

```rust
struct DeviceMap {
    map: Mutex<HashMap<Key, Weak<Device>>>,
}

fn clear_inactive(&self) {
    self.map.lock().retain(|_, weak| weak.upgrade().is_some());
}
```

The pool doesn't keep resources alive. Windows hold `Arc` references that determine lifetime. When all windows using a device close, their Arcs drop, and the `Weak` can no longer upgrade.

Periodic cleanup removes dead entries from the pool. The pool itself never delays reclamation—it just tracks what's available for sharing.

This is elegant for shared resources with uncertain lifetimes. The pool enables sharing without owning. Resources die when their actual users are done, not when the pool decides.

---

## Context Validity: When the World Changes

Processing targets environments where GPU contexts can disappear:

```java
boolean contextIsOutdated() {
    boolean outdated = !pgl.contextIsCurrent(context);
    if (outdated) {
        dispose();
    }
    return outdated;
}
```

On mobile, backgrounding the app invalidates the GL context. On web, canvas resize might destroy and recreate it. All GPU resources tied to the old context become invalid—using them is undefined behavior.

Processing tracks which context created each resource. Before use, it checks validity. If the context has changed, the resource auto-disposes and recreates as needed.

This pattern matters less for desktop wgpu, where contexts are more stable. But the underlying lesson applies: GPU resources exist within a context, and that context has a lifetime.

---

## The Safety-Efficiency Tradeoff

More aggressive reclamation:
- Frees memory sooner
- Requires more careful lifetime tracking
- Risks use-after-free bugs

More conservative reclamation:
- Wastes memory temporarily
- Simplifies lifetime management
- Guarantees safety

For creative coding, conservative usually wins. Memory is abundant; debugging use-after-free is painful. Err toward safety, optimize toward efficiency only when memory pressure proves problematic.

---

## Lessons for Flux

The reclamation research suggests a layered approach:

**Rely on wgpu's automatic handling by default.** Drop handles, let wgpu schedule cleanup. For most resources, this is sufficient and safe.

**Implement frame-delayed deletion for explicit management.** If Flux manages resources in pools or instruction queues, delay actual deletion by 2+ frames. This handles in-flight commands safely.

**Consider sessions for lifetime boundaries.** Scene transitions, effect lifetimes, loading phases—these are natural cleanup points. Sessions can group resources that should die together.

**Avoid aggressive reclamation unless memory pressure demands it.** Explicit `destroy()` calls are bug-prone. Use them sparingly, for known-lifetime resources at clear boundaries.

**Don't fight the frame rhythm.** The natural pattern is: dirty flags → uploads → render → deletions. Process deletions at frame end, after GPU work is submitted. This keeps reclamation predictable.

---

## Related Documents

- [per-framework/wgpu.md](per-framework/wgpu.md) — Drop-based cleanup
- [per-framework/rend3.md](per-framework/rend3.md) — Instruction queue deletion
- [per-framework/openrndr.md](per-framework/openrndr.md) — Session-based cleanup
- [per-framework/nannou.md](per-framework/nannou.md) — Weak reference pattern
