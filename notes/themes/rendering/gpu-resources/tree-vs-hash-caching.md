# Tree-Based vs Hash-Based Bind Group Caching

How should a GPU resource system cache bind groups: traverse a tree of resource IDs, or compute a hash and look up in a flat map?

---

## The Core Tension

Bind groups are expensive to create. Each `GPUBindGroup` requires validation of resource compatibility, layout matching, and internal driver state setup. In a typical frame, a production engine might need thousands of unique bind groups—one per material/mesh combination, plus per-object uniform buffers, per-frame global data, and texture bindings.

The naive approach recreates bind groups every frame. This works for demos but collapses under real workloads. Caching is essential.

But cache lookup has its own cost. The key question: **what data structure should back the cache?**

Two patterns dominate:
1. **Tree-based caching**: Walk a tree where each level branches on one resource ID
2. **Hash-based caching**: Compute a hash from all resource IDs, lookup in a flat map

Babylon.js chose trees. Most frameworks choose hashes. Both work. Understanding *why* each excels reveals deep insights about GPU resource access patterns.

---

## Pattern A: Tree-Based Caching (Babylon.js)

### Context: Production WebGPU Engine

Babylon.js is one of the most mature WebGPU implementations, battle-tested across thousands of production sites. Their bind group cache uses a tree structure that exploits the hierarchical nature of rendering: many objects share the same global buffers, materials share textures, and variations occur only at leaf nodes.

### How It Works: Tree Traversal

```typescript
class WebGPUBindGroupCacheNode {
    public values: { [id: number]: WebGPUBindGroupCacheNode };
    public bindGroups: GPUBindGroup[];
}

// ID offsets prevent collision across resource types
const BufferIdStart = 1 << 20;      // 1,048,576
const TextureIdStart = 2 ** 35;     // 34,359,738,368

public getBindGroups(
    pipelineContext: WebGPUPipelineContext,
    drawContext: WebGPUDrawContext,
    materialContext: WebGPUMaterialContext
): GPUBindGroup[] {
    let node = WebGPUCacheBindGroups._Cache;

    // Walk tree by buffer IDs
    for (const bufferName of pipelineContext.shaderProcessingContext.bufferNames) {
        const uboId = (drawContext.buffers[bufferName]?.uniqueId ?? 0) + BufferIdStart;
        let nextNode = node.values[uboId];
        if (!nextNode) {
            nextNode = new WebGPUBindGroupCacheNode();
            node.values[uboId] = nextNode;
        }
        node = nextNode;
    }

    // Continue walking: samplers, then textures
    for (const samplerName of pipelineContext.shaderProcessingContext.samplerNames) {
        const samplerId = materialContext.samplers[samplerName]?.hashCode ?? 0;
        let nextNode = node.values[samplerId];
        if (!nextNode) {
            nextNode = new WebGPUBindGroupCacheNode();
            node.values[samplerId] = nextNode;
        }
        node = nextNode;
    }

    for (const textureName of pipelineContext.shaderProcessingContext.textureNames) {
        const textureId = (materialContext.textures[textureName]?.uniqueId ?? 0) + TextureIdStart;
        let nextNode = node.values[textureId];
        if (!nextNode) {
            nextNode = new WebGPUBindGroupCacheNode();
            node.values[textureId] = nextNode;
        }
        node = nextNode;
    }

    // At leaf: check for cached bind groups
    if (node.bindGroups) {
        return node.bindGroups;
    }

    // Cache miss: create bind groups and store at this leaf
    const bindGroups = this.createBindGroups(pipelineContext, drawContext, materialContext);
    node.bindGroups = bindGroups;
    return bindGroups;
}
```

### The Flow: Tree Structure

```
                         [Root]
                           │
            ┌──────────────┼──────────────┐
            │              │              │
      [UBO: Scene]   [UBO: Scene]   [UBO: Scene]
      id=1048577     id=1048577     id=1048578
            │              │              │
      ┌─────┴─────┐        │              │
      │           │        │              │
 [UBO: Mesh]  [UBO: Mesh]  ...           ...
 id=1048590   id=1048591
      │           │
      │           │
 [Sampler]   [Sampler]
 hash=42     hash=42        ← Same sampler, tree merges here
      │           │
      │           │
 [Texture]   [Texture]
 id=2^35+1   id=2^35+2      ← Different textures = different leaves
      │           │
      │           │
 bindGroups  bindGroups     ← Cached GPUBindGroup[] at leaves
```

### When It Excels

**High prefix sharing**: Scenes where thousands of objects share the same scene UBO, camera UBO, and lighting setup. Only per-object buffers and textures vary. The tree collapses redundant prefix lookups into shared nodes.

**Predictable traversal order**: The pipeline context dictates resource order. Same shader = same traversal path. No sorting or normalization needed.

**Zero collision risk**: Each unique resource combination maps to exactly one leaf node. No hash collision handling, no bucket chains, no rehashing.

**Incremental invalidation**: When a texture changes, only subtrees below that texture node need invalidation. Parent nodes remain valid.

---

## Pattern B: Hash-Based Caching

### Context: Traditional Approach

Most rendering engines use hash-based caching for bind groups, pipeline states, and other GPU objects. The pattern is familiar from general-purpose programming: compute a key, look up in a hash map.

### How It Works: Hashing Resource IDs

```javascript
function computeBindGroupKey(buffers, samplers, textures) {
    let hash = 0;

    // FNV-1a style accumulation
    for (const buffer of buffers) {
        hash = hash * 31 + buffer.id;
        hash = hash | 0;  // Keep as 32-bit integer
    }

    for (const sampler of samplers) {
        hash = hash * 31 + sampler.hashCode;
        hash = hash | 0;
    }

    for (const texture of textures) {
        hash = hash * 31 + texture.id;
        hash = hash | 0;
    }

    return hash;
}

// Cache lookup
function getOrCreateBindGroup(layout, buffers, samplers, textures) {
    const key = computeBindGroupKey(buffers, samplers, textures);

    if (cache.has(key)) {
        // Potential collision: must verify resources match
        const cached = cache.get(key);
        if (resourcesMatch(cached.resources, buffers, samplers, textures)) {
            return cached.bindGroup;
        }
        // Hash collision: fall through to create new
    }

    // Cache miss or collision: create and store
    const bindGroup = device.createBindGroup({
        layout: layout,
        entries: buildEntries(buffers, samplers, textures)
    });

    cache.set(key, {
        bindGroup: bindGroup,
        resources: { buffers, samplers, textures }
    });

    return bindGroup;
}
```

### The Flow: Hash Lookup

```
┌─────────────────────────────────────────────────────────┐
│                    Resource IDs                          │
│  buffers: [101, 102]  samplers: [42]  textures: [501]   │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │   Hash Computation    │
              │   hash = f(101, 102,  │
              │           42, 501)    │
              │   result = 0x7A3F21B8 │
              └───────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    HashMap                               │
│  ┌────────┬────────┬────────┬────────┬────────┐        │
│  │ bucket │ bucket │ bucket │ bucket │ bucket │  ...   │
│  │   0    │   1    │   2    │   3    │   4    │        │
│  └────────┴────────┴────────┴────────┴────────┘        │
│                          │                               │
│                          ▼                               │
│              ┌───────────────────────┐                  │
│              │  Entry @ bucket 2     │                  │
│              │  key: 0x7A3F21B8      │                  │
│              │  value: GPUBindGroup  │                  │
│              │  resources: [...]     │ ← For collision  │
│              └───────────────────────┘   verification   │
└─────────────────────────────────────────────────────────┘
```

### When It Excels

**Uniform resource patterns**: When bind groups have similar numbers of resources and no clear prefix hierarchy. Hash lookup is O(1) regardless of resource count.

**Simple implementation**: One hash function, one map. No tree node allocation, no pointer chasing. Easier to reason about and debug.

**Memory efficiency with sparse combinations**: If resource combinations are sparse (few objects share common prefixes), a flat map wastes less memory than a deep tree with mostly single-child nodes.

**Language/runtime support**: Hash maps are highly optimized in most runtimes. JavaScript's `Map`, Rust's `HashMap`, C++'s `unordered_map` all have decades of optimization.

---

## Side-by-Side Comparison

| Dimension | Tree-Based (Babylon.js) | Hash-Based |
|-----------|------------------------|------------|
| **Lookup complexity** | O(n) where n = resource count | O(1) average, O(n) worst |
| **Collision handling** | Impossible by design | Required (verification or chaining) |
| **Prefix sharing** | Automatic, structural | None (each combo independent) |
| **Memory overhead** | Node objects per resource | Entry + stored resources per combo |
| **Cache invalidation** | Subtree pruning possible | Full scan or versioned keys |
| **Implementation complexity** | Higher (tree traversal) | Lower (hash + map) |
| **Debugging** | Tree structure is inspectable | Hash values opaque |
| **Fast-path potential** | High (dirty tracking + skip) | Moderate (still must hash) |

---

## Combining the Patterns

The most sophisticated systems combine both approaches. A two-level cache can capture the best of both worlds: tree-based for structural sharing, hash-based for final lookup.

### Hybrid Approach

```rust
use std::collections::HashMap;

/// Two-level bind group cache: tree for structure, hash for final lookup
pub struct HybridBindGroupCache {
    /// First level: tree indexed by bind group set index (0-3)
    set_trees: [BindGroupTreeNode; 4],
}

struct BindGroupTreeNode {
    /// Children indexed by resource category hash (fast discrimination)
    children: HashMap<u64, BindGroupTreeNode>,
    /// Leaf storage: full hash -> bind group
    bind_groups: HashMap<u64, CachedBindGroup>,
}

struct CachedBindGroup {
    bind_group: wgpu::BindGroup,
    resource_ids: Vec<ResourceId>,  // For collision verification
    last_used_frame: u64,
}

impl HybridBindGroupCache {
    pub fn get_or_create(
        &mut self,
        set_index: usize,
        resources: &BindGroupResources,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
    ) -> &wgpu::BindGroup {
        // Level 1: Tree traversal by category
        let category_hash = resources.category_hash();
        let tree_node = self.set_trees[set_index]
            .children
            .entry(category_hash)
            .or_insert_with(BindGroupTreeNode::new);

        // Level 2: Hash lookup within category
        let full_hash = resources.full_hash();

        if let Some(cached) = tree_node.bind_groups.get_mut(&full_hash) {
            // Verify no collision (rare but possible)
            if cached.resource_ids == resources.ids() {
                cached.last_used_frame = self.current_frame;
                return &cached.bind_group;
            }
            // Collision: fall through to create with different key
        }

        // Cache miss: create bind group
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("cached_bind_group"),
            layout,
            entries: &resources.to_entries(),
        });

        tree_node.bind_groups.insert(full_hash, CachedBindGroup {
            bind_group,
            resource_ids: resources.ids().to_vec(),
            last_used_frame: self.current_frame,
        });

        &tree_node.bind_groups.get(&full_hash).unwrap().bind_group
    }

    /// Prune bind groups not used in recent frames
    pub fn evict_stale(&mut self, max_age_frames: u64) {
        let cutoff = self.current_frame.saturating_sub(max_age_frames);

        for tree in &mut self.set_trees {
            tree.evict_before(cutoff);
        }
    }
}
```

### Babylon.js's Fast-Path: Beyond Caching

Babylon.js adds another layer that transcends the tree-vs-hash debate: **dirty tracking to skip the cache entirely**.

```typescript
public static NumBindGroupsCreatedTotal = 0;
public static NumBindGroupsCreatedLastFrame = 0;
public static NumBindGroupsLookupLastFrame = 0;
public static NumBindGroupsNoLookupLastFrame = 0;  // Fast path!

public getBindGroups(
    pipelineContext: WebGPUPipelineContext,
    drawContext: WebGPUDrawContext,
    materialContext: WebGPUMaterialContext
): GPUBindGroup[] {
    // Fast path: if nothing changed, return cached bind groups directly
    if (!drawContext.isDirty(materialContext.updateId) && !materialContext.isDirty) {
        WebGPUCacheBindGroups._NumBindGroupsNoLookupCurrentFrame++;
        return drawContext.bindGroups!;  // Skip entire cache lookup
    }

    // Slow path: walk the tree...
    WebGPUCacheBindGroups._NumBindGroupsLookupCurrentFrame++;
    // ... tree traversal code ...
}
```

This fast path dominates in stable scenes. The per-frame statistics reveal the pattern:
- `NumBindGroupsNoLookupLastFrame`: Objects unchanged since last frame (fast path)
- `NumBindGroupsLookupLastFrame`: Objects that needed cache lookup
- `NumBindGroupsCreatedLastFrame`: True cache misses

In a stable scene, the fast path might handle 95%+ of draw calls.

---

## Implications for the GPU Resource Pool

### Recommendation 1: Use Trees for Hierarchical Binding Models

WebGPU's binding model is inherently hierarchical. Bind group 0 is typically per-frame (camera, time, global settings). Bind group 1 is per-material. Bind group 2 is per-object. This hierarchy maps naturally to a tree structure.

```rust
/// Bind group cache organized by set frequency
pub struct BindGroupCache {
    /// Set 0: Per-frame globals (single node, rarely changes)
    per_frame: Option<CachedBindGroup>,

    /// Set 1: Per-material (tree by material ID)
    per_material: HashMap<MaterialId, CachedBindGroup>,

    /// Set 2: Per-object (tree by mesh ID, then instance ID)
    per_object: HashMap<MeshId, HashMap<InstanceId, CachedBindGroup>>,

    /// Set 3: Per-draw dynamic (often recreated, minimal caching)
    per_draw: LruCache<u64, CachedBindGroup>,
}
```

### Recommendation 2: Implement Multi-Level Dirty Tracking

Babylon.js's statistics show that dirty tracking yields the biggest wins. Don't just cache bind groups—track *why* they might need updating.

```rust
#[derive(Default)]
pub struct DirtyFlags {
    /// Generation counter for scene-level changes
    pub scene_generation: u64,
    /// Generation counter for material changes
    pub material_generation: u64,
    /// Per-object dirty bits
    pub object_dirty: BitVec,
}

impl DrawContext {
    /// Fast path: check if any relevant state changed
    pub fn needs_bind_group_update(&self, dirty: &DirtyFlags) -> bool {
        self.last_scene_gen != dirty.scene_generation
            || self.last_material_gen != dirty.material_generation
            || dirty.object_dirty.get(self.object_index).unwrap_or(true)
    }
}
```

### Recommendation 3: Expose Statistics for Observability

Babylon.js's approach of tracking cache behavior per frame is invaluable for optimization. The resource pool should expose similar metrics.

```rust
#[derive(Default, Debug)]
pub struct BindGroupCacheStats {
    /// Total bind groups ever created
    pub total_created: u64,
    /// Bind groups created this frame
    pub created_this_frame: u32,
    /// Cache lookups this frame
    pub lookups_this_frame: u32,
    /// Fast-path hits (no lookup needed)
    pub fast_path_hits: u32,
    /// Cache hit rate (lookups that found existing)
    pub hit_rate: f32,
}
```

### Recommendation 4: ID Offset Trick for Type Safety

Babylon.js's ID offset pattern (`BufferIdStart = 1 << 20`, `TextureIdStart = 2 ** 35`) prevents accidental collisions between resource types. In Rust, we can encode this in the type system.

```rust
/// Resource ID with embedded type tag
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ResourceId(u64);

impl ResourceId {
    const BUFFER_TAG: u64 = 0x1 << 60;
    const TEXTURE_TAG: u64 = 0x2 << 60;
    const SAMPLER_TAG: u64 = 0x3 << 60;

    pub fn buffer(id: u32) -> Self {
        Self(Self::BUFFER_TAG | id as u64)
    }

    pub fn texture(id: u32) -> Self {
        Self(Self::TEXTURE_TAG | id as u64)
    }

    pub fn sampler(id: u32) -> Self {
        Self(Self::SAMPLER_TAG | id as u64)
    }
}
```

### Recommendation 5: Consider Eviction Strategy

Both patterns need eviction to prevent unbounded growth. Trees can prune entire subtrees when parent resources are destroyed. Hash maps need LRU or frame-based eviction.

```rust
impl BindGroupCache {
    /// Evict bind groups not used in `max_age` frames
    pub fn evict_stale(&mut self, current_frame: u64, max_age: u64) {
        let cutoff = current_frame.saturating_sub(max_age);

        // For tree: walk and prune nodes with no recent access
        // For hash: iterate and remove old entries
        self.per_draw.retain(|_, cached| cached.last_used >= cutoff);
    }

    /// Invalidate all bind groups using a specific resource
    pub fn invalidate_resource(&mut self, resource_id: ResourceId) {
        // Tree advantage: can prune entire subtree
        // Hash: must scan all entries
    }
}
```

---

## Conclusion

Babylon.js's tree-based bind group cache is a sophisticated solution optimized for real-world rendering patterns. The hierarchical structure mirrors WebGPU's binding model, enabling prefix sharing and structural invalidation. Hash-based caching remains simpler and performs well for uniform resource patterns.

For a new Rust creative coding framework, consider a hybrid approach: tree-based organization for the inherent hierarchy of bind group sets, with hash-based final lookup for flexibility. Most importantly, implement multi-level dirty tracking to enable fast-path skipping—this yields larger performance gains than cache structure alone.

The observability patterns (per-frame statistics, cache hit rates) transform bind group management from a black box into a tunable system.

---

## Related Documents

- [gpu-resource-management.md](../gpu-resource-management.md) — Resource pool architecture overview
- [frame-graph.md](../../per-library/web/babylonjs/frame-graph.md) — Babylon.js frame graph implementation
- [wgpu-backend.md](../../../insights/architecture-decisions.md) — ADR on wgpu as graphics backend
- [rendering-pipeline.md](../../per-framework/nannou/rendering-pipeline.md) — Nannou's approach to GPU resources
