# Vello Sparse Strips: Coverage Only Where the Edge Is

> What if the GPU never saw your path's triangles, because there were none?

## Key Insight

> **The core idea:** A filled path is stored as horizontal runs of 4x4 pixel tiles that touch its outline, each with 16 exact coverage bytes, plus one flag saying "everything between this run and the previous one is solid". Alpha memory scales with the perimeter of the shape, not its area, and the GPU draws plain quads instead of a triangle mesh.

---

## The Problem: Triangles Do Not Know How Much of a Pixel They Cover

Take a filled circle. The tessellation approach in the [tessellation theme](../../../themes/vector-graphics/tessellation.md) flattens the outline into line segments, then triangulates the interior into a mesh and uploads it as a vertex buffer. The rasterizer then decides, per pixel, whether a triangle covers the pixel centre. That test is binary. A pixel the outline cuts in half is either in or out, so the edge staircases.

Tessellation-based renderers fix this in one of two ways. They turn on MSAA, which multiplies the samples the GPU shades and stores along every edge, or they emit extra geometry along the outline (a thin fringe of translucent triangles) that fades from opaque to transparent. Both work. Both also tie anti-aliasing quality to something other than the actual geometry: sample count in one case, fringe width in the other. Both make you pay per frame to rebuild a mesh whenever the path changes.

Sparse strips take a different route. They compute the exact fraction of each pixel the shape covers, from the flattened line segments, on the CPU. They only do this where an edge actually passes through. The huge interior of the shape needs no per-pixel math, because its coverage is trivially 100 percent. The result is a compact description (strips and alpha bytes) that a vertex/fragment pipeline can draw with no compute shaders and no triangulation. This document walks through that representation stage by stage. For the end-to-end call stack from `Scene::fill_path` to pixels, see the [fill-path code trace](code-traces/fill-path.md), which this document links to rather than repeating.

---

## The Mental Model: A Shape as Rows of Tiles, Mostly Empty

Picture a newspaper crossword with the answer grid printed in faint blue. You do not describe a big black region square by square. You say "row 3, squares 5 through 9 are black", and you only draw detail at the ragged boundary where a letter shape bleeds into the next square. Sparse strips work the same way.

Slice the screen into rows that are 4 pixels tall, and slice each row into 4-pixel-wide tiles. A scan-converted shape then falls into three kinds of tile on each row:

- **Outside tiles** that the shape never touches. They store nothing.
- **Edge tiles** that an outline passes through. Each needs full detail: 16 coverage values, one per pixel.
- **Interior tiles** completely inside the shape. They need one fact, "solid", for the whole run.

A **strip** is a run of consecutive edge tiles on one row. Between two strips on the same row there is a gap, and a flag on the second strip (`fill_gap`) says whether that gap is inside the shape. Here is one row of a circle, with edge tiles marked `E` and interior tiles marked `#`:

```
tile row y=7:   . . . E E # # # # # # E E . . .
                      \___/\__________/\___/
                    strip 1  implied   strip 2
                    (alpha)   gap      (alpha, fill_gap = true)
```

The picture shows why "sparse" is the right word. Only the `E` tiles carry bytes. The long `#` span costs a flag and a width, however wide the circle gets.

---

## The Pipeline, Stage by Stage

Three stages turn a path into strips. They live in `vello_common/src/` and share one scratch buffer pattern: each stage fills a `Vec` that the next stage consumes.

| Stage | Input | Output | File |
|-------|-------|--------|------|
| Flatten | Bezier path, transform | `Vec<Line>` | `flatten.rs` |
| Tile | `Vec<Line>` | sorted `Vec<Tile>` (which line touches which 4x4 cell) | `tile.rs` |
| Strip | sorted tiles, lines | `Vec<Strip>` + `Vec<u8>` alpha bytes | `strip.rs` |

### Flatten: Curves to Lines, and Throw Away What Cannot Matter

Flattening is the same first step tessellators take: replace curves with short straight segments. The output type is deliberately tiny.

**File:** `vello_common/src/flatten.rs:76`

A `Line` holds two `f32` points, `p0` and `p1`, and nothing else. The tolerance is a hardcoded 0.25 pixels (the comment explains that `sqrt` does not work in const contexts, so the code stores the square root and the square as constants).

**File:** `vello_common/src/flatten.rs:15-19`

You might expect a flatten stage to emit a closed polygon. It does not, and the reason is the most interesting detail in the file. The renderer only keeps geometry inside the viewport, but the winding number at the viewport's left edge depends on geometry outside it. The doc comment on `fill` draws this out in ASCII art: the winding scan runs left to right, so only lines to the left of the viewport and lines crossing it matter. Lines above, below and to the right can be dropped. The comment then warns that you must keep the surviving subpaths open. Closing them would invent new edges and change the winding.

**File:** `vello_common/src/flatten.rs:90-177`

Two more rules to know. A NaN anywhere in the path discards the whole path and logs a warning, so one bad control point silently removes a shape rather than corrupting the frame.

**File:** `vello_common/src/flatten.rs:212-216`

Strokes never get their own rasterizer. `stroke` asks kurbo to expand the stroke into an outline path (a filled shape in the shape of the stroke), then calls the same `fill`. The tolerance is divided by the transform's scale as a stated temporary hack.

**File:** `vello_common/src/flatten.rs:221-250`

### Tile: Bin Every Line into the 4x4 Cells It Crosses

The tiling stage asks one question per line segment: which 4x4 cells does it pass through? It does no coverage math. The doc comment calls this "coarse binning".

**File:** `vello_common/src/tile.rs:514`

Each answer is one `Tile`, and a line crossing five cells produces five tiles. A tile has to say where it is (`x`, `y` in tile units), which line made it, and how the line meets the cell. Vello packs the last two into one 32-bit word: 27 bits for the line index and 5 flag bits (top, bottom, left, right intersections, plus a winding bit that is set when the line crosses the tile's top edge). That caps a path at 2^27 lines (`MAX_LINES_PER_PATH`, derived from the flag width).

**File:** `vello_common/src/tile.rs:239-245`, `vello_common/src/tile.rs:41`

The tile size is two constants.

**File:** `vello_common/src/tile.rs:263-266`

```rust
pub const WIDTH: u16 = 4;
pub const HEIGHT: u16 = 4;
```

Sorting is where the layout choice pays off. The next stage needs tiles in reading order, row by row and left to right. Vello orders the struct fields so that the in-memory value, read as a `u64`, is `(y, x, packed_winding_line_idx)`. Converting a tile to its sort key then costs nothing. The code comment admits the line index is not needed for correctness, only for memory locality when the strip stage looks up lines: "this operation compiles to a no-op" (the sort is a plain `sort_unstable`).

**File:** `vello_common/src/tile.rs:379-388`, `vello_common/src/tile.rs:478-482`

One more wrinkle. When the flatten stage culls geometry to the left of the viewport, that geometry still changes the winding of every row to its right. The `CulledWindings` struct stores per-row integer winding (`coarse`), per-scanline fractional winding (`partial`) and a bitmask of active rows, so the strip stage can reconstruct the fill without keeping the lines.

**File:** `vello_common/src/tile.rs:45`

### Strip: Turn Edge Tiles into Alpha Bytes and Runs

The strip stage consumes the sorted tiles and produces the representation the rest of the system uses. Its output type is small.

**File:** `vello_common/src/strip.rs:17-27`

```rust
pub struct Strip {
    pub x: u16,                     // pixel x of the strip's first tile
    pub y: u16,                     // pixel y of the strip's row
    packed_alpha_idx_fill_gap: u32, // bit 31: fill_gap, bits 0..=30: alpha_idx
}
```

Notice what is missing: a width. A strip's width is the distance from its own `alpha_idx` to the next strip's, divided by 4 rows (`width_to`, with a doc warning that it returns garbage if `next` is not the adjacent strip).

**File:** `vello_common/src/strip.rs:236`

That is why the stage ends every output with a sentinel strip at `x = u16::MAX`, and why consumers always iterate `windows(2)`.

**File:** `vello_common/src/strip.rs:218`, `vello_common/src/strip.rs:348-353`

Now the heart of it. For every tile, in sorted order, `render_impl` accumulates the signed area each line contributes. The accumulator is `[f32x4; 4]`: one SIMD vector of four row values for each of the four columns. A tile is 4 rows tall, which fits a 128-bit vector, and the code comments say this assumption is explicit.

**File:** `vello_common/src/strip.rs:331`, `vello_common/src/strip.rs:402-404`

The comment above the area code explains the math. Conceptually, fire a horizontal ray from left to right. Each line crossing upward adds one to the winding, each crossing downward subtracts one. A pixel's coverage is the integral of that winding across the pixel. In practice each pixel gets the trapezoid between the line and the pixel's right edge, and the line's vertical extent in that pixel feeds every pixel to its right.

**File:** `vello_common/src/strip.rs:584-613` (the math comment), `vello_common/src/strip.rs:689-719` (the code)

The core of the loop looks like this:

```rust
let area = h * (line_px_right_yx + line_px_left_yx).mul_add(-0.5, px_right_x);
location_winding[x_idx as usize] += area.mul_add(sign, acc);
acc = h.mul_add(sign, acc);
```

Here `h` is how much of the line's height falls inside this pixel, and the first line is the trapezoid area. The second line adds the trapezoid plus whatever winding the pixels to the left already pushed rightward (`acc`). The third line updates that carry. The worked example below traces these three lines on a real tile.

When the sweep moves to a new tile location, the accumulated area becomes bytes. Under the NonZero rule the byte is `min(255, |area| * 255 + 0.5)`. Under EvenOdd the area folds back and forth like a triangle wave, so overlapping regions cancel.

**File:** `vello_common/src/strip.rs:451-485`, `vello_common/src/util.rs:24-49` (`f32_to_u8` truncates through `to_int`, so the `+ 0.5` supplies the rounding)

If the caller sets an aliasing threshold, every byte snaps to 0 or 255, which turns off anti-aliasing for pixel-art style rendering.

**File:** `vello_common/src/strip.rs:492-498`

Then the code appends exactly 16 bytes, one 4x4 tile of alpha, to the alpha buffer.

**File:** `vello_common/src/strip.rs:487-500`

When the next tile is not adjacent to the previous one, the current strip ends and a new one starts. The new strip's `fill_gap` flag comes from the winding carried across the gap: `should_fill(winding_delta)`, with a guard so a strip that begins at the viewport's left edge never claims a gap that does not exist.

**File:** `vello_common/src/strip.rs:509-515`, `vello_common/src/strip.rs:565-570`

At the end of each row, if the winding is still non-zero, the stage pushes a zero-width strip at the viewport's right edge with `fill_gap` set, so the last interior span has an endpoint.

**File:** `vello_common/src/strip.rs:519-528`

Geometry that was culled on the left produces "captive" and "background" rows: solid strips built from the row winding alone. Even these write one 16-byte tile of 255s, because the clipping code (per its own TODO) only accepts zero-width strips as row terminators.

**File:** `vello_common/src/strip.rs:287-308`, `vello_common/src/strip.rs:370-386`

### Consuming Strips: Alpha Segments and Solid Segments

Downstream code does not walk strips directly. It calls `visit_strip_fill_segments`, which looks at each adjacent pair and emits up to two things per pair: an alpha segment for the strip's own tiles (`StripAlphaFillSegment`, carrying an `alpha_idx`) and, if `next_strip.fill_gap()` is set on the same row, a plain solid segment for the gap (`StripFillSegment`, no alpha).

**File:** `vello_common/src/strip.rs:116`, `vello_common/src/strip.rs:32`, `vello_common/src/strip.rs:57`, `vello_common/src/strip.rs:178-193`

The [fill-path trace](code-traces/fill-path.md) (steps 3-5 and 9-12) shows how these segments become 24-byte GPU instances and what the shaders do with them. This document stops at the representation.

---

## A Worked Example: One Tile, One Diagonal Line

This section traces the method by hand on one tile. The coverage values (0, 0.5, 1) are exactly representable in `f32`, so the byte values below match what the code produces.

Take one 4x4 tile. A single flattened line runs from the tile's top-left corner (0, 0) to its bottom-right corner (4, 4), and the shape's interior lies to the right and above it (the upper-right triangle). The line has slope 1. For each pixel in the tile, ask: what fraction of this pixel lies to the right of the line?

Number the pixels by row `r` and column `c`, both 0 to 3. The line is `y = x`, so it passes through the four diagonal pixels `(r, r)`, and nowhere else inside the tile.

1. **Pixels left of the diagonal (`c < r`)** sit below-left of the line. The line never enters them, and the carry from pixels to their left is zero. Coverage is 0.
2. **Diagonal pixels (`c == r`)** are cut corner to corner. In the code's terms, the line's vertical extent in the pixel is `h = 1`. The line enters at the pixel's left edge at local height `y = r` and leaves at the right edge at `y = r + 1`. The trapezoid between the line and the right edge, over the pixel's full height, has two parallel sides at distance 1 and 0 from the right edge: area = 1 x (1 + 0) / 2 = 0.5.
3. **Pixels right of the diagonal (`c > r`)** are never touched by the line, but the diagonal pixel in their row passed `h = 1` into the carry (`acc`). That carry adds a full unit of winding. Coverage is 1.

Written as a grid of coverage fractions (rows top to bottom, columns left to right):

```
         c=0   c=1   c=2   c=3
  r=0   0.5   1.0   1.0   1.0
  r=1   0.0   0.5   1.0   1.0
  r=2   0.0   0.0   0.5   1.0
  r=3   0.0   0.0   0.0   0.5
```

A sanity check: the covered area should be half the tile. Four diagonal pixels at 0.5 contribute 2, and six pixels at 1.0 contribute 6. The total is 8 out of 16, which is exactly the upper-right half of the square.

Now convert to bytes with the NonZero formula, `min(255, coverage * 255 + 0.5)`. A coverage of 0.5 gives 127.5 + 0.5 = 128.0, and `f32_to_u8` truncates that to 128. (Truncation is why the formula adds 0.5 first: it makes the conversion round to nearest.) A coverage of 1.0 gives 255, and 0.0 gives 0. The alpha buffer stores columns, not rows: each of the four `f32x4` accumulators holds one column's four row values, and the 16 bytes are the columns concatenated.

```
alpha bytes, column-major (4 bytes per column, rows top to bottom):
  col 0: 128   0   0   0
  col 1: 255 128   0   0
  col 2: 255 255 128   0
  col 3: 255 255 255 128
```

That is the whole payload for this tile. The fragment shader later reads one byte per pixel from it. Pixels to the right of this tile on the same row are fully inside the shape, and they appear in the data as a `fill_gap` span: no bytes at all.

Two cautions on the simplification. First, a real line that ends exactly on the tile corner, as this one does, produces extra tiles in neighbouring cells in the tile stage, and the tile intersection flags decide which tile owns the crossing. This example treats the tile in isolation. Second, a real edge with a steeper slope puts different `h` values into each row, and the area formula handles fractional `h` the same way: it only needs the line's top and bottom y within each pixel.

---

## Clipping Is Strip Intersection

Most renderers treat a clip as GPU state: a stencil buffer, a scissor, a mask texture. Sparse strips have a representation that makes a better option available. A clip path is itself just a filled path, so it already exists as strips and alphas. Clipping a drawn path against it then means intersecting two strip lists.

**File:** `vello_common/src/clip.rs:393`

The doc comment describes the algorithm in four cases. It walks both paths' strips and fill regions in lock step and finds every overlap.

- Fill region against fill region: the overlap is a fill region.
- Strip against fill region: the overlap copies the strip's alpha mask.
- Strip against strip: the overlap multiplies the two masks together (the doc says "combine").
- Regions filled in neither path are ignored.

**File:** `vello_common/src/clip.rs:402-412`

Think of two stencils laid over each other. Where both are open paper, light passes. Where one is a half-transparent frosted edge and the other is open, you keep the frost. Where both are frosted you stack the frosting. The result is a new stencil, which is a new strip list.

The caller side is short. When a clip is active, `render_with_clip` renders the path into temporary storage first, wraps that as a `PathDataRef`, then calls `intersect` to write the combined strips into the scene's storage. Without a clip, it renders straight into scene storage.

**File:** `vello_common/src/strip_generator.rs:274-297`

The clip itself is described by `ClipShape`, either an arbitrary `Path` or a known `AxisAlignedRect`, wrapped in a `ClipRef` that holds the strip data.

**File:** `vello_common/src/clip.rs:374`

This is why the GPU never sees a clip. By the time strips are recorded, the clip has already been multiplied into them. The shaders draw instanced quads and read alpha bytes, with no stencil state, no scissor per clip and no mask pass. That keeps the shader and pipeline surface small, and it keeps the GPU side identical for clipped and unclipped content. The price is that clipping costs CPU time, once per clipped path per frame.

---

## What "Sparse" Saves

The savings fall in three places, and it helps to count them for a concrete shape. Take the circle of radius 120 from the code trace. These numbers are back-of-envelope estimates from geometry, not measurements.

**Alpha storage.** The circle's area is about 45,000 pixels. A dense coverage mask would be about 45 KB at one byte per pixel. The outline crosses roughly `(|dx| + |dy|) / 4` tiles per unit of path, and the total of `|dx| + |dy|` around a circle is `8r`, so about 240 edge tiles, each 16 bytes: roughly 3.8 KB. Double the radius and the dense mask quadruples, while the tile count only doubles. Alpha storage grows with the perimeter.

**Fragment reads.** An interior solid segment is encoded with `dense_width = 0`, and the fragment shader only samples the alpha texture when the strip is not a rect and `dense_end_or_rect_size != 0`. Interior fragments take the `alpha = 1.0` default and never touch the alpha texture.

**File:** `vello_gpu_shaders/shaders/render.wesl:398-404`

**Geometry.** A tessellated fill of the same circle needs a vertex per flattened outline point at minimum (a convex polygon with n points triangulates into n - 2 triangles), plus an index buffer and, for anti-aliasing, MSAA samples or fringe triangles. The sparse version issues instanced quads: a handful per tile row, one for each strip plus one for each filled gap, and the outline detail lives in the alpha bytes instead of in triangle count. Zoom in and the tessellated mesh must be rebuilt at a finer tolerance or it shows facets. The sparse version re-runs flatten at the new transform and gets exact edges again.

### The Costs

Nothing is free, and the costs here are the mirror image of the savings.

- **CPU time for every path, every time it is built.** Flatten, tile, sort and strip generation all run on the CPU (SIMD-dispatched at runtime). `Scene::fill_path` does this work at call time. If the caller rebuilds the scene each frame, every path pays the full cost every frame. Nothing is cached across frames unless the caller keeps the `Scene` and does not re-record. Tessellation has a similar CPU cost, but tessellated meshes are easy to cache and replay under a changing transform. A strip list is tied to the pixel grid, so a moving or scaling shape needs a rebuild.
- **A whole-alpha-buffer upload each frame.** The renderer uploads the entire alpha buffer as one chunk. The source carries a TODO that suggests a bounded buffer and draw breaks when it fills.

**File:** `vello_gpu/src/render/wgpu/mod.rs:549-551`

- **Scene-size limits.** Because one texture holds all the alphas, a large scene meets texture size limits first. The code trace notes this for small devices.

---

## How This Compares to Tessellation and Stencil-Based Fills

The table compares three ways to turn a filled path into pixels. The Lyon column reflects the study's [tessellation theme](../../../themes/vector-graphics/tessellation.md). The stencil-and-fringe column describes the NanoVG-style fill that openrndr uses: a CPU-built fan plus fringe geometry, drawn with three stencil passes for non-convex shapes. The [openrndr contour-to-pixels trace](../../../per-framework/openrndr/code-traces/contour-to-pixels.md) documents it (`ExpansionDrawer.kt:231-363`).

| | Lyon tessellation (nannou) | Stencil + fringe (NanoVG style, as in openrndr) | Sparse strips (Vello) |
|---|---|---|---|
| **Where coverage is computed** | GPU rasterizer, per triangle, by sample position | GPU stencil pass for inside/outside, plus a fringe of geometry for edges | CPU, analytically, per edge pixel |
| **AA quality** | Needs MSAA or extra geometry; quality tracks sample count | Soft edges from the fringe width; fixed ramp | Exact area coverage at the flattening tolerance (0.25 px) |
| **Per-frame CPU cost** | Zero if the mesh is cached; full re-tessellation if the path changes | Low: emits outline and fringe geometry | Flatten, tile, sort and strip generation for every path you rebuild |
| **GPU requirements** | Plain vertex/fragment; MSAA targets | Needs a stencil buffer and multiple passes per path | Plain vertex/fragment with an `Rgba32Uint` texture; no compute (WebGL2 backend exists) |
| **Memory** | Vertex and index buffers, grows with triangle count; MSAA targets multiply framebuffer memory | Small vertex buffers; stencil attachment | Alpha bytes proportional to perimeter; instance buffer; one alpha texture |
| **Self-overlapping paths** | Lyon handles them, with the tessellator doing the work | Stencil winding handles them natively | Winding accumulates in the strip stage; NonZero and EvenOdd both supported |
| **Zoom** | Re-tessellate at a finer tolerance or accept facets | Fringe width is in screen pixels, geometry stays flat | Re-flatten at the new transform; always pixel-exact edges |

The trade is clear from the table. Tessellation moves coverage onto the GPU's fixed-function rasterizer and pays in cacheability and anti-aliasing quality. Stencil fills stay cheap on the CPU and pay in GPU passes and state. Sparse strips pay CPU time and one upload per frame and in return get exact edges on hardware with no special features.

---

## Where This Came From

Upstream traces the design in `ARCHITECTURE.md`. It says the Sparse Strips renderers "grew from" the sparse rendering approach in the Potato design document, and points to a master thesis for the full pipeline description. It adds a caveat: parts of the thesis are already outdated, and implementation details continue to evolve.

**File:** `ARCHITECTURE.md:44-48`

- Potato: *a hybrid CPU/GPU 2D renderer design*, `https://docs.google.com/document/d/1gEqf7ehTzd89Djf_VpkL0B_Fb15e0w5fuv_UzyacAPU/edit`
- Vello CPU thesis (ETH Zurich), `https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Thesis.pdf`

**File:** `ARCHITECTURE.md:119`

Read the thesis for the reasoning, then trust the source for the current numbers. For example, the tolerance (0.25) and tile size (4x4) in this document come straight from the code at commit 65338c25, not from the thesis.

---

## Gotchas

- **A `Strip` slice is not self-describing.** Width comes from the next strip, so a sub-slice that drops the sentinel gives garbage widths. Always keep the sentinel, and iterate with `windows(2)`.
- **Culled-left geometry still costs bytes.** Background and captive rows write a full 16-byte tile of 255s even though the content is solid.
- **Horizontal lines contribute nothing to winding.** The strip loop skips them (the code carries a TODO to cull them earlier, at tile generation).

**File:** `vello_common/src/strip.rs:574-578`

- **The `fill_gap` flag lives on the right-hand strip.** It describes the gap to its left, not its own tiles.
- **A path with too many lines degrades visually.** `MAX_LINES_PER_PATH` is 2^27, and its doc comment warns of artifacts beyond it.

---

## Implications for Flux

- **Adopt: edge-only coverage with interior spans.** Store alpha bytes per 4x4 edge tile and represent interiors as a flag plus an extent. Upload and fragment bandwidth then scale with perimeter, and the format works with plain vertex/fragment pipelines on web and mobile.
- **Adopt: clipping as a CPU-side set operation on the same representation.** Intersecting strip lists keeps the GPU free of stencil and mask state. A Flux 2D layer gets clips with no extra pipelines.
- **Adopt: layout-driven sort keys.** Pack tile coordinates and line index so the memory value is the sort key. It costs nothing and removes a key-extraction pass.
- **Modify: store a width on the strip.** Two extra bytes per strip would remove the sentinel and `windows(2)` coupling, or a newtype could guarantee the sentinel's presence.
- **Modify: bound the alpha upload.** Replace the whole-buffer upload with a ring or chunked store and break the draw when it fills, as the upstream TODO suggests. Small texture limits on mobile and WebGL2 make this matter.
- **Avoid: re-recording everything every frame by default.** Sparse strips are cheap per path but not free. Flux should let callers keep a recorded scene and replay it, and keep tessellation (cached Lyon meshes) available for static geometry where it wins.

---

## Sources

- `libraries/rust/vello/vello_common/src/flatten.rs`, `tile.rs`, `strip.rs`, `strip_generator.rs`, `clip.rs`
- `libraries/rust/vello/vello_gpu_shaders/shaders/render.wesl`
- `libraries/rust/vello/vello_gpu/src/render/wgpu/mod.rs`
- `libraries/rust/vello/ARCHITECTURE.md`
- [Fill-path code trace](code-traces/fill-path.md), [Vello README](README.md), [Tessellation theme](../../../themes/vector-graphics/tessellation.md)
- [Potato design document](https://docs.google.com/document/d/1gEqf7ehTzd89Djf_VpkL0B_Fb15e0w5fuv_UzyacAPU/edit)
- [Vello CPU thesis](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Thesis.pdf) (upstream says parts are outdated)

---

*This document is part of the [Vello study](README.md).*
