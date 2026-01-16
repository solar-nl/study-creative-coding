# Session-Based vs. Frame-Delayed Cleanup: Grouping by Lifetime vs. Temporal Safety

> When can a GPU resource actually be freed? The CPU says "now," but the GPU is still reading from it.

---

## The Core Tension

CPU and GPU execute asynchronously. When your code finishes with a buffer, the CPU has moved on to the next frame. But the GPU might still be executing draw calls from two frames ago that reference that buffer. Free the memory while the GPU reads from it, and you corrupt the frame or crash the driver.

Two fundamental patterns address this:

**Session-based cleanup** groups resources by semantic lifetime. A scene session owns scene resources; when the scene ends, everything in the session cleans up. Safety comes from understanding *what* resources belong together and *when* their collective lifetime ends.

**Frame-delayed cleanup** defers deletion by a fixed number of frames. Mark a resource for deletion in frame N, actually delete in frame N+2. Safety comes from temporal guarantees: wait long enough, and all GPU references are gone.

Both patterns ensure safe deletion. But they offer different mental models: sessions think in terms of ownership hierarchies, frame-delay thinks in terms of GPU command latency. Understanding both—and when to use each—is key to robust resource management.

---

## Pattern A: Session-Based Cleanup (OpenRNDR)

### Context

Creative coding applications have natural hierarchies. The application owns scenes, scenes own effects, effects own temporary buffers. These aren't arbitrary groupings—they reflect how artists think about their work. A scene transition means "everything about this scene goes away." An effect ending means "this effect's resources are no longer needed."

OpenRNDR's session system maps resource lifetime directly to this hierarchy.

### How It Works

Each session tracks the resources created within it:

```kotlin
class Session {
    val parent: Session?
    val children: MutableList<Session>
    val colorBuffers = mutableSetOf<ColorBuffer>()
    val vertexBuffers = mutableSetOf<VertexBuffer>()

    fun end() {
        children.forEach { it.end() }  // Cascade to children
        colorBuffers.forEach { it.destroy() }
        colorBuffers.clear()
        // ... other resources
    }
}
```

Resource creation automatically registers with the current session:

```kotlin
// Resource auto-registration
fun createColorBuffer(...): ColorBuffer {
    val colorBuffer = ColorBufferGL3.create(...)
    session?.track(colorBuffer)  // Register with current session
    return colorBuffer
}
```

The programmer doesn't track individual resources. They create a session, create resources within it, and end the session when done. The session handles the rest.

### Hierarchical Cleanup

Sessions nest naturally. The root session lives for the application lifetime. Child sessions represent scenes, frames, or effects:

```
Application Session (root)
    |
    +-- Scene A Session
    |       |
    |       +-- Effect 1 Session
    |       +-- Effect 2 Session
    |
    +-- Scene B Session
            |
            +-- Effect 3 Session
```

Ending a parent cascades to children:

```
Session.end() called on "Scene A Session"
    |
    +-- Effect 1 Session.end() [triggered by parent]
    |       |
    |       +-- destroy() all Effect 1 colorBuffers
    |       +-- destroy() all Effect 1 vertexBuffers
    |
    +-- Effect 2 Session.end() [triggered by parent]
    |       |
    |       +-- destroy() all Effect 2 resources
    |
    +-- destroy() all Scene A resources
```

One call cleans up an entire subtree. No manual tracking, no forgetting individual resources.

### Destruction Guards

Resources track their own destruction state:

```kotlin
override fun destroy() {
    if (!isDestroyed) {
        session?.untrack(this)
        isDestroyed = true
        glDeleteBuffers(buffer)
    }
}
```

This prevents double-free bugs. The session can safely iterate and destroy; already-destroyed resources become no-ops.

### When Sessions Excel

- **Clear lifetime boundaries.** Level transitions, scene changes, application shutdown—these are natural session boundaries.
- **Grouped resources.** Effects with multiple buffers, scenes with multiple render targets—everything dies together.
- **Mental model match.** When artists think "this scene is done," sessions clean up what "this scene" means.
- **Hierarchical composition.** Nested sessions mirror nested program structure.

---

## Pattern B: Frame-Delayed Deletion (rend3)

### Context

Game engines and continuous renderers lack clear boundaries. There's no "scene end" event—scenes stream in and out. Objects spawn and despawn mid-frame. Content loads asynchronously while rendering continues.

In this environment, lifetime boundaries are fuzzy. What's clear is the GPU's command latency: typically 2-3 frames of commands are in flight. Delete a resource, wait that long, and it's safe.

### How It Works

Resources marked for deletion enter a queue. Each frame, the queue advances. Deletions from N frames ago finally execute:

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

The flow across frames:

```
Frame 0: mark_for_delete(ResourceA)
         pending_deletes = [A]
         frame_delete_queues = []

         process_frame_end():
         frame_delete_queues = [[A]]

Frame 1: mark_for_delete(ResourceB)
         pending_deletes = [B]

         process_frame_end():
         frame_delete_queues = [[A], [B]]

Frame 2: mark_for_delete(ResourceC)
         pending_deletes = [C]

         process_frame_end():
         queue length (3) > delay (2), so:
         actually_delete(ResourceA)  // Safe now!
         frame_delete_queues = [[B], [C]]

Frame 3: process_frame_end():
         actually_delete(ResourceB)
         frame_delete_queues = [[C]]
```

Resources deleted in frame N are actually freed in frame N+2 (with delay=2). By then, any commands referencing them have completed.

### Why This Delay?

Modern GPUs double- or triple-buffer. When frame N starts rendering, frames N-1 and N-2 might still be executing. A 2-frame delay ensures:

- Frame N's commands complete before frame N+2 starts
- Any resource referenced in frame N is safe to delete in frame N+2

The delay is conservative. Some resources might be safe to delete sooner. But "slightly conservative" beats "occasionally corrupt."

### When Frame-Delay Excels

- **Streaming content.** Assets load and unload continuously; no natural boundaries.
- **Continuous rendering.** Games that never pause, simulations that run indefinitely.
- **Unknown lifetime.** Resources shared across subsystems with unclear ownership.
- **Guaranteed safety.** No reasoning about "when is it safe"—the delay ensures it.

---

## Side-by-Side Comparison

| Dimension | Session-Based | Frame-Delayed |
|-----------|---------------|---------------|
| Cleanup trigger | Explicit session.end() | Frame boundary + delay elapsed |
| Safety mechanism | Programmer ensures session outlives GPU work | Temporal guarantee (wait N frames) |
| Mental model | Ownership hierarchies | Command latency |
| Best for dynamic content | Moderate (fine-grained sessions) | Excellent (no boundaries needed) |
| Works with boundaries | Excellent (designed for them) | Works but ignores them |
| Memory overhead | Minimal (cleanup immediate at boundary) | Slight (resources linger N frames) |
| Predictability | High (cleanup when you say) | High (cleanup after known delay) |

---

## Combining the Patterns

The patterns aren't mutually exclusive. A sophisticated system can use both:

Sessions organize resources by semantic lifetime—"these resources belong to this effect." Frame-delay ensures temporal safety—"wait until the GPU is done."

When a session ends, instead of immediately destroying resources, it marks them for frame-delayed deletion:

```rust
pub struct Session {
    resources: Vec<ResourceId>,
    children: Vec<Session>,
    pool: Arc<Mutex<ResourcePool>>,
}

impl Session {
    pub fn track(&mut self, id: ResourceId) {
        self.resources.push(id);
    }

    pub fn end(self) {
        // End children first
        for child in self.children {
            child.end();
        }

        // Mark for delayed deletion, not immediate destruction
        let mut pool = self.pool.lock().unwrap();
        for id in self.resources {
            pool.mark_for_delete(id);
        }
        // Actual deletion happens N frames later
    }
}
```

The session provides the "when" (semantic lifetime), and frame-delay provides the "safely" (temporal guarantee).

A hybrid cleanup flow:

```
User calls session.end() for "Scene A"
    |
    +-- Child sessions cascade-end
    |
    +-- All resources mark_for_delete()
    |       Resources enter pending_deletes queue
    |
    +-- Session struct dropped (no resources owned now)

... 2 frames later ...

    +-- process_frame_end() runs
    |
    +-- Resources from "Scene A" actually_delete()
            GPU definitely done with them now
```

This combination is powerful for editor-style applications. Scene transitions feel immediate—the session ends, the UI updates. But the actual GPU cleanup waits until safe.

```rust
pub struct Editor {
    active_scene: Option<Session>,
    resource_pool: Arc<Mutex<ResourcePool>>,
}

impl Editor {
    pub fn switch_scene(&mut self, new_scene: SceneData) {
        // End old scene session (marks resources for delayed delete)
        if let Some(old_session) = self.active_scene.take() {
            old_session.end();
        }

        // Create new scene session immediately
        let mut new_session = Session::new(self.resource_pool.clone());
        self.load_scene_resources(&mut new_session, new_scene);
        self.active_scene = Some(new_session);

        // Old scene resources are queued for deletion
        // New scene resources are loading
        // Both are safe: old resources wait 2 frames, new ones are fresh
    }
}
```

---

## Implications for the GPU Resource Pool

### Default: Let wgpu Handle It

For most resources in a creative coding framework, wgpu's built-in drop handling is sufficient:

```rust
{
    let buffer = device.create_buffer(&desc);
    render_pass.set_vertex_buffer(0, buffer.slice(..));
}  // Buffer dropped here; wgpu schedules cleanup safely
```

wgpu internally tracks when resources are referenced by in-flight commands. It won't actually free memory until safe. This is the simplest approach and handles the common case.

### Pools: Add Frame-Delayed Deletion

When managing resources through explicit pools (for caching, reuse, or instruction queues), add frame-delayed deletion:

```rust
impl TexturePool {
    pub fn release(&mut self, handle: TextureHandle) {
        // Don't delete immediately—queue for later
        self.pending_deletes.push(handle);
    }

    pub fn process_frame(&mut self) {
        // Move pending to delayed queue
        let this_frame = std::mem::take(&mut self.pending_deletes);
        self.delayed_queues.push_back(this_frame);

        // Process queue from 2 frames ago
        if self.delayed_queues.len() > 2 {
            for handle in self.delayed_queues.pop_front().unwrap() {
                self.textures.remove(handle);
                // wgpu::Texture drops here, safe now
            }
        }
    }
}
```

This is especially important when pool indices might be reused. A 2-frame delay ensures old commands don't accidentally reference a reused slot.

### Hierarchies: Consider Sessions

For editor scenarios or applications with clear scene structure, sessions provide ergonomic cleanup:

```rust
impl App {
    pub fn unload_effect(&mut self, effect_id: EffectId) {
        if let Some(session) = self.effect_sessions.remove(&effect_id) {
            session.end();  // Everything for this effect cleans up
        }
    }
}
```

Sessions are optional complexity. Start without them; add if the application structure demands.

### When Explicit destroy() Is Warranted

Explicit destruction is appropriate for:
- **Known single-use resources.** A loading screen texture, used once, never referenced again.
- **Memory pressure.** When you need memory back immediately, not in 2 frames.
- **Explicit lifecycle.** Render targets with clear create/use/destroy patterns.

```rust
// Explicit destroy for single-use
let screenshot = take_screenshot();
save_to_disk(&screenshot);
screenshot.destroy();  // Done immediately, memory back now
```

But prefer the default (drop) or frame-delayed (pool) approaches for most resources. Explicit destroy requires careful reasoning about GPU state.

---

## Conclusion

Session-based and frame-delayed cleanup address the same underlying problem—GPU asynchrony—with different mental models.

Sessions think in ownership: "These resources belong together and should die together." This matches how creative coders often think about their work. It's natural at boundaries—scene changes, effect completion, application shutdown.

Frame-delay thinks in time: "Wait long enough, and it's safe." This handles the continuous case elegantly. No boundaries needed, no ownership reasoning required. Just queue and wait.

The best systems use both. Sessions for structure, frame-delay for safety. `session.end()` expresses intent; the pool ensures the GPU is ready. Together, they provide both ergonomic lifetime management and bulletproof safety.

---

## Related Documents

- [per-framework/openrndr.md](per-framework/openrndr.md) — Session-based tracking in detail
- [per-framework/rend3.md](per-framework/rend3.md) — Instruction queue and delayed deletion
- [reclamation-timing.md](reclamation-timing.md) — When memory returns across frameworks
