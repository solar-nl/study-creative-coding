# The Compute Renderer: Vello's Road Not Taken

> What if the CPU did nothing per frame except write down the scene, and the GPU worked out all the geometry by itself?

## Key Insight

> **The core idea:** The original Vello turns the sequential parts of 2D rendering (flattening, binning, clip stacks, tile lists) into prefix-scan problems, so a chain of about twenty compute dispatches can replace the CPU's scanline work. It is the most GPU-native 2D renderer in the repo, and upstream still demoted it to `research/` because the price is compute-shader hardware and fragile scratch memory.

## The Problem: Per-Frame Geometry Work Is the CPU's Bottleneck

A classic 2D renderer spends its frame on geometry. It walks each path, turns curves into line segments, decides which pixels each segment touches, and keeps a stack of clips and blend layers. Almost all of that is sequential. Segment 7's output offset depends on how many segments came before it, and a clip's bounding box depends on the clips it nests inside. A CPU handles that gracefully. A GPU, with thousands of threads and no cheap way to say "wait for my left neighbour", does not.

The usual workaround is to split the work. The CPU does the sequential part (tessellate with Lyon, rasterize scanlines, build strips) and the GPU does the parallel part (fill pixels). That is the road the Sparse Strips renderers took. It works, but the CPU cost grows with scene complexity, and every animated path pays it again each frame. The compute renderer asks a bolder question: can the sequential-looking steps be reformulated so the GPU does them too?

The answer is the parallel prefix sum, also called a scan. Think of a ticket counter at a deli. Each customer needs a number, and that number is "how many people were ahead of me". Counting by walking down the line is sequential. But if the line splits into groups, each group counts its own members, the groups then sum their totals, and each customer adds their group's starting number to their local count, then everyone gets a ticket in parallel. That is reduce-then-scan. Vello applies it to path segments, draw objects, and clip stacks, and the rest of the pipeline follows from that choice.

## Scene Encoding: Write It Down, Do Nothing Else

For the GPU to do all the work, the CPU needs to hand over the scene in a form that needs no interpretation. The `vello_encoding` crate defines that form. Its crate doc is one line, "Raw scene encoding" (**File:** `research/vello_encoding/src/lib.rs:4`), and its centre is the `Encoding` struct.

The struct splits a scene into parallel streams instead of an array of fixed-size elements. Here is the heart of it, trimmed to the fields that matter:

```rust
pub struct Encoding {
    pub path_tags: Vec<PathTag>,   // one byte per path segment or marker
    pub path_data: Vec<u32>,       // all coordinates, compared bitwise
    pub draw_tags: Vec<DrawTag>,   // one tag per draw object
    pub draw_data: Vec<u32>,       // per-object payload (colour, gradient...)
    pub transforms: Vec<Transform>,
    pub styles: Vec<Style>,        // fill/stroke flags and line width
    pub resources: Resources,      // late-bound data, patched before upload
    pub n_paths: u32, pub n_path_segments: u32,
    pub n_clips: u32, pub n_open_clips: u32,
    // ...
}
```

**File:** `research/vello_encoding/src/encoding.rs:26`

Each stream answers a different question for a different shader. Path tags and path data describe geometry. Draw tags and draw data describe what to paint. Transforms and styles sit in their own streams so a stroke width or matrix is stored once, not once per segment. The `Resources` struct (**File:** `research/vello_encoding/src/encoding.rs:560`) holds the late-bound items: patches, colour stops for gradients, glyphs, glyph runs, and normalized variable-font coordinates. A `Resolver` later swaps those references for real atlas coordinates before the buffer goes to the GPU (`Resolver` is exported at `research/vello_encoding/src/lib.rs:69`).

### Why Tags Instead of Structs

The tag-stream design predates the Rust crate. `research/doc/pathseg.md` explains it as the November 2021 element-processing rewrite. The old encoding gave every element a fixed 36 bytes, which would only grow as new element types arrived. The new one separates a tag byte from a packed payload. The tag byte alone tells you the payload size, so an exclusive prefix sum over those sizes gives each segment its start offset, and tag plus offset is everything a thread needs to unpack its segment. Bits 0-1 give the segment type (line, quad, cubic), bit 2 marks the last segment of a subpath so consecutive segments can share endpoints, and bit 3 chooses 16-bit or 32-bit coordinates. Bits 4-6 are one-hot markers for a path, a transform and a line width. The design even counts the payload of four tags at once using bit tricks on a `u32` (**File:** `research/doc/pathseg.md:47-61`). The current code still follows it. For example, `PathTag::LINE_TO_F32` is `0x9`, a line with the 32-bit flag (**File:** `research/vello_encoding/src/path.rs:252`).

You can think of this like a shipping manifest. The manifest lists the size of each box, not the contents. Anyone with the manifest can compute where box 500 sits in the truck without opening boxes 1-499, which is exactly what a GPU thread needs.

The roadmap gives one data point on density: encoding the 14MB paris-30k SVG takes about 12MB with 32-bit coordinates (**File:** `research/doc/roadmap_2023.md:112`).

## The Pipeline: Twenty Dispatches, Three Parallel Patterns

The renderer's shader list in `FullShaders` is the table of contents for the whole pipeline (**File:** `research/vello_research/src/shaders.rs:19-45`). `render_encoding_coarse` then records one dispatch per stage. The table follows that order. "Binds" lists the buffers named in each dispatch's argument list. Newly allocated buffers in that call are the stage's outputs. Only the `binning` and `coarse` rows were checked against their WGSL; the other rows are inferred from the `render.rs` buffer lists.

| Stage | Binds (reads, then new outputs) | Parallel pattern | Source line |
|-------|--------------------------------|------------------|-------------|
| `pathtag_reduce` | config, scene, then `reduced_buf` | Reduce: one monoid per workgroup | `render.rs:250` |
| `pathtag_reduce2`, `pathtag_scan1` | `reduced_buf`, then `reduced2`, `reduced_scan` | Extra reduce and scan levels, only for very large scenes | `render.rs:263`, `:272` |
| `pathtag_scan` (or `_large`) | scene, parent sums, then `tagmonoid_buf` | Scan: every tag gets its running offsets | `render.rs:290` |
| `bbox_clear` | then `path_bbox_buf` | Plain data-parallel clear | `render.rs:304` |
| `flatten` | scene, tag monoids, bump counters, then `lines_buf` | Per-segment parallel; bump allocation for output lines | `render.rs:317` |
| `draw_reduce` | scene, then `draw_reduced_buf` | Reduce over draw tags | `render.rs:333` |
| `draw_leaf` | scene, draw sums, path bboxes, then draw monoids, bin data, clip inputs | Scan finish, per draw object | `render.rs:346` |
| `clip_reduce`, `clip_leaf` | clip inputs, path bboxes, then clip BIC buffer, clip elements, clip bboxes | Reduce and scan over the clip stack (the "stack monoid" posts) | `render.rs:369`, `:380` |
| `binning` | config, draw monoids, path bboxes, clip bboxes, then draw bboxes, bump, bin data, bin headers (checked against `binning.wgsl`, bindings 0-7) | Per-object, bump allocated | `render.rs:405` |
| `tile_alloc` | scene, draw bboxes, bump, then `path_buf`, `tile_buf` | Per-path tile allocation from a bump counter | `render.rs:425` |
| `path_count_setup` | bump counters, then `indirect_count_buf` | Tiny kernel that writes a dispatch size | `render.rs:443` |
| `path_count` | lines, paths, tiles, bump, then `seg_counts_buf` | Indirect dispatch sized by line count | `render.rs:452` |
| `backdrop` | paths, tiles | Resolves per-tile backdrop values (I did not read the shader) | `render.rs:465` |
| `coarse` | config, scene, draw monoids, bin headers, bin data, paths, tiles, bump, then `ptcl_buf` (checked against `coarse.wgsl`, bindings 0-8) | Per-bin; builds per-tile command lists | `render.rs:470` |
| `path_tiling_setup` | bump counters | Writes the next indirect size | `render.rs:485` |
| `path_tiling` | seg counts, lines, paths, tiles, then `segments_buf` | Indirect dispatch sized by segment count | `render.rs:490` |
| `fine_area` / `fine_msaa8` / `fine_msaa16` | segments, ptcl, bin data, blend spill, gradient and atlas images, then the output image | Dispatched over the image tiles; the only stage that writes the output image | `render.rs:560` (`record_fine`) |

The shape matters more than the individual stages. Early stages (`pathtag_*`, `draw_*`, `clip_*`) are scans, which compute offsets and bounding boxes with no knowledge of the output. Middle stages (`flatten` through `coarse`) turn geometry into per-tile work lists, and they cannot know their output sizes in advance, so they use bump counters. The two `*_setup` kernels exist so that indirect dispatches can size themselves from those counters. Only `fine` produces pixels.

### Tracing One Frame

Here is what happens to a scene with one filled circle and one gradient rectangle.

1. The CPU appends path tags (four cubics for the circle, four lines for the rectangle) and two draw tags to the encoding. It never flattens a curve.
2. `Resolver::resolve` packs the streams into one `scene` buffer and builds a gradient ramp image (**File:** `research/vello_research/src/render.rs:148`).
3. `pathtag_reduce` and `pathtag_scan` give every segment its offset into `path_data`.
4. `flatten` turns each cubic into lines, and each thread reserves its output slots with a bump counter.
5. `binning`, `tile_alloc` and `path_count` work out which 16x16 tiles each line crosses (`TILE_WIDTH`/`TILE_HEIGHT` are 16 at **File:** `research/vello_encoding/src/config.rs:12-13`).
6. `coarse` writes a command list per tile: "fill with path 0, then paint gradient 1".
7. `fine` reads those command lists and writes the pixels.

Between steps 3 and 6, the only CPU involvement is submission.

## The Recording Model: Declare the Graph, Then Replay It

Twenty dispatches over a dozen intermediate buffers is a lot to manage by hand. The compute renderer separates describing the work from running it. A `Recording` is just a list of commands (**File:** `research/vello_research/src/recording.rs:25-27`), and `Command` covers upload, download, clear, free, `Dispatch` and `DispatchIndirect` (**File:** `research/vello_research/src/recording.rs:64-87`).

Think of it as a shopping list handed to a personal shopper. The recording says "dispatch `flatten` with these buffers" using lightweight handles, `BufferProxy` and `ImageProxy`, which carry a size and an ID but no GPU memory (**File:** `research/vello_research/src/recording.rs:31-35`). The `WgpuEngine` is the shopper. Its `run_recording` walks the list, creates a command encoder, and turns proxies into real buffers as it goes (**File:** `research/vello_research/src/wgpu_engine.rs:380-397`). For an upload it asks a pool for a buffer of the right size and writes into it (**File:** `research/vello_research/src/wgpu_engine.rs:408-413`). The recording also frees each buffer after its last use (the `free_resource` calls scattered through `render.rs`), which gives the pool the chance to recycle memory. I did not trace the pool's reuse policy.

The roadmap names the payoff. The recording is "an appealing alternative to an object-oriented hardware abstraction layer", and it could support lightweight native backends (**File:** `research/doc/roadmap_2023.md:130`). The same engine also carries a `use_cpu` flag (**File:** `research/vello_research/src/wgpu_engine.rs:38`) that swaps in CPU kernels per shader (**File:** `research/vello_research/src/wgpu_engine.rs:262-270`), which brings us to shader tooling.

### The Bump Allocator and the Failure It Creates

Here is where it gets interesting, and where the design is honest about its weakness. `flatten`, `binning`, `tile_alloc` and `coarse` produce output whose size depends on the scene's geometry after transformation. Nobody knows, until the GPU runs, how many lines a cubic will flatten into. So the renderer allocates scratch buffers up front, and the shaders claim slots by atomically incrementing counters in a `BumpAllocators` struct. Its fields are `failed`, `binning`, `ptcl`, `tile`, `seg_counts`, `segments`, `blend` and `lines` (**File:** `research/vello_encoding/src/config.rs:26-37`). The comment on the counters states the rule: they hold the final needed size, and "if any of these are larger than the corresponding `_size` element reallocation needs to occur" (**File:** `research/vello_encoding/src/config.rs:28-29`).

A bump allocator is like a ticket dispenser with a fixed roll. Each thread tears off as many tickets as it needs, and when the roll runs out, the later threads get nothing. The struct has a `failed` field for exactly this case, and the counters keep the size each stage wanted. Upstream's answer is "robust dynamic memory": read the counters back, then reallocate and rerun if any counter exceeded its buffer. Here is what this checkout actually contains:

- `render_encoding_full` is documented as "not recommended when the scene can be complex, as it does not implement robust dynamic memory" (**File:** `research/vello_research/src/render.rs:95-98`).
- `render_encoding_coarse` takes a `robust` flag, which schedules a download of the bump buffer (**File:** `research/vello_research/src/render.rs:133-134`, `:528-530`).
- The async path reads those counters back between coarse and fine, but a TODO notes that the logic "to determine whether we need to rerun coarse" is still missing (**File:** `research/vello_research/src/lib.rs:764-765`). It also sets `robust` only when the `debug_layers` feature is on (**File:** `research/vello_research/src/lib.rs:729-732`).
- The `with_winit` example describes the async pipeline as "one approach for robust memory" (issue 366), with the downside that it blocks the main thread for extended periods (**File:** `research/examples/with_winit/src/lib.rs:85-94`).
- An optional `bump_estimate` feature adds a `BumpEstimator` that gives "conservative size estimation" that "naturally overestimates" (**File:** `research/vello_encoding/src/estimate.rs:4-5`). Its own notes say binning, ptcl and tile estimation are still TODO (**File:** `research/vello_encoding/src/estimate.rs:14-16`).
- Very large render targets trigger a warning that points to issue 680 (**File:** `research/vello_research/src/render.rs:206-218`).

I did not find a completed readback-and-retry loop in this checkout, so treat "robust" as an aspiration the code documents, not a shipped guarantee.

## Shader Tooling: WGSL With a Tiny Preprocessor

The compute stages are WGSL files in `research/vello_shaders/shader/`. WGSL has no includes or conditionals, so the crate adds two features (**File:** `ARCHITECTURE.md:98-104`): `import` for shared code from `shader/shared`, and `ifdef`/`ifndef`/`else`/`endif` driven by definitions supplied from outside. The preprocessor in `compile/preprocess.rs` loads every `.wgsl` file from the `shared` directory into an import table (**File:** `research/vello_shaders/src/compile/preprocess.rs:8-30`), then scans each line for `#` directives and keeps a stack of active conditionals (**File:** `research/vello_shaders/src/compile/preprocess.rs:32-70`). This is how one source produces the three fine-rasterizer variants (area, msaa8, msaa16).

Because the stages are small and data-oriented, each has a Rust twin in `research/vello_shaders/src/cpu/`, with one module per stage (**File:** `research/vello_shaders/src/cpu.rs:15-33`). The twins serve testing. The module doc says the CPU implementation is "useful for testing and debugging" and that "a full CPU fallback as an alternative to GPU shaders is not provided" (**File:** `research/vello_shaders/src/cpu.rs:6-7`). `ARCHITECTURE.md` says the same: use `vello_cpu` for a real CPU renderer (**File:** `ARCHITECTURE.md:63-65`). The bump logic is mirrored too, so a GPU artifact can be bisected by swapping one stage at a time between CPU and GPU.

## Requirements and Trade-offs

The device setup shows how little the renderer asks of wgpu and how much it asks of the GPU. It requests default limits and optionally `CLEAR_TEXTURE | PIPELINE_CACHE`, intersected with what the adapter offers (**File:** `research/vello_research/src/util.rs:167-172`, `:169`). Nothing there is exotic. The hard requirement is the compute-capable GPU itself, since the stages cannot run on WebGL2. The README describes the crate as "an experimental implementation for compute-capable GPUs" (**File:** `README.md:37-40`), and the research README says it "requires a compute-capable GPU" (**File:** `research/README.md:3-5`).

| You get | You pay |
|---------|---------|
| No per-frame CPU geometry work beyond encoding | Compute shaders required; no WebGL2 path |
| Dynamic, vector-heavy scenes perform very well (`ARCHITECTURE.md:58-59`) | Large GPU scratch buffers (lines, tiles, segments, ptcl, blend spill) |
| Same pipeline for fills, strokes, clips, blends | Memory sizing is a dynamic-scene hazard (bump failure above) |
| Encoding is compact and cacheable | One encoded buffer, many interdependent stages to debug |

The memory column is the subtle one. The CPU-side renderers fail gracefully when a scene is big, because the CPU knows the size of what it produced. The compute renderer finds out on the GPU, after the fact.

## Why Upstream Moved It to `research/`

Three pieces of upstream wording explain the decision. `ARCHITECTURE.md` calls it "the experimental `vello` renderer" and says it "requires compute shader support and has different compatibility and memory trade-offs from the Sparse Strips renderers" (**File:** `ARCHITECTURE.md:8-9`, `:58-61`). The README says Vello GPU "is intended to become the primary renderer for production GPU use cases as it matures", with a native WebGL2 backend and a wgpu backend "without requiring compute shaders" (**File:** `README.md:31-33`, `:29-30`). The 2023 roadmap had already named the pressure. Under "Deep compatibility work" it says Vello targets "GPUs of today" and does not want to spend most of its effort accommodating primitive devices (**File:** `research/doc/roadmap_2023.md:176-182`). Its answer then was a CPU fallback for the compute stages and a "compatibility" fine rasterizer. The Sparse Strips split reaches the same goal by moving the compute stages to the CPU by default.

The arc runs through the blog list in `research/doc/blogs.md` (**File:** `research/doc/blogs.md:3-18`):

- *2D Graphics on Modern GPU*, May 8, 2019: the piet-gpu starting point.
- *piet-gpu progress report*, Jun 1, 2020.
- *A sort-middle architecture for 2D graphics*, Jun 12, 2020.
- *Fast 2D rendering on GPU*, Jun 13, 2020.
- *Prefix sum on Vulkan*, Apr 30, 2020, and *The stack monoid*, Sep 5, 2020: the scan machinery for clips.
- *The stack monoid revisited*, May 13, 2021, and *Prefix sum on portable compute shaders*, Nov 17, 2021.
- *piet-gpu progress: clipping*, Feb 24, 2022.
- *Requiem for piet-gpu-hal*, Jan 7, 2023 (the date comes from the URL; the list entry itself omits it): the move to wgpu.
- Paper: *Fast GPU bounding boxes on tree-structured scenes* (arXiv 2205.11659).

In story form: piet-gpu was a research renderer on Vulkan and other native APIs. In late 2022 it was renamed Vello, since it no longer relied on the Piet API (**File:** `research/doc/roadmap_2023.md:5`), and rewritten in WGSL on wgpu. The roadmap then aimed to ship a production renderer from that base. The repo today instead treats the compute design as research, and the production work sits in Sparse Strips, which grew from the *Potato* hybrid CPU/GPU design (**File:** `ARCHITECTURE.md:44-48`). I did not open any document that records the decision meeting or benchmark comparison, so the "why" above rests on the compatibility and memory language in the docs, not on measurements.

## What This Still Offers Flux

- **A feature-gated compute path for path-heavy scenes.** Sparse Strips cost grows with CPU flatten and tile work. A scene with many animated paths could, in principle, skip that cost entirely by encoding once and letting the GPU do the rest. The compute renderer is the only place in the repo that shows that end of the trade-off.
- **Prefix scans as a reference for any GPU-driven geometry.** Particle compaction, instanced draw lists, node-graph evaluation and clip stacks all hit the same "who goes where" question. The `reduce -> scan -> leaf` shape in `render.rs:250-346` is a worked pattern, and the portable-scan blog posts explain the portability limits.
- **Tag streams for compact scene data.** The `pathseg.md` design (separate tag stream, size-by-tag, prefix sum for offsets) is a good model for any Flux scene format that must be cheap to produce on the CPU and cheap to unpack on the GPU.
- **The recording abstraction.** Proxies plus a replayable command list make a render graph that is declarative, testable and backend-neutral. Flux's renderer layer could borrow that shape regardless of which rasterizer sits beneath it.
- **The indirect-dispatch idiom.** The `*_setup` kernel writing a dispatch size for the next stage is a general trick for GPU-driven work. It comes with a wgpu usage rule worth remembering: the counter buffer cannot be both indirect-count and writable in one pass, which is why `IndirectCount` is separate from `BumpAllocators` (**File:** `research/vello_encoding/src/config.rs:106-110`).

Next steps: read [code-traces/fill-path.md](code-traces/fill-path.md) for the Sparse Strips side of the same question, then compare the two in [cpu-gpu-split.md](cpu-gpu-split.md). Back to the [Vello README](README.md). Upstream paths such as `ARCHITECTURE.md` live in [the submodule](../../../../libraries/rust/vello/ARCHITECTURE.md).

## Sources

- `libraries/rust/vello/ARCHITECTURE.md`, `README.md`, `research/README.md`
- `libraries/rust/vello/research/vello_encoding/src/{lib,encoding,path,config,estimate}.rs`
- `libraries/rust/vello/research/vello_research/src/{shaders,render,recording,wgpu_engine,util,lib}.rs`
- `libraries/rust/vello/research/vello_shaders/src/{cpu.rs,compile/preprocess.rs}`
- `libraries/rust/vello/research/doc/{pathseg,roadmap_2023,blogs}.md`
- `libraries/rust/vello/research/examples/with_winit/src/lib.rs`
- Blogs by Raph Levien, listed above, at `raphlinus.github.io`
- Studied at vello commit `65338c258f09`, `vello` 0.11.0
