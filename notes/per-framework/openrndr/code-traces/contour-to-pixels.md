# Code Trace: openrndr `drawer.contour()` to pixels

> Tracing `drawer.contour(c)` for a closed `ShapeContour` with fill and stroke, from user code to `glDrawArrays`.

## Overview

**Framework**: openrndr (checkout `00c47af75ddc`, 2026-10-11)
**Operation**: Draw one closed Bézier contour with fill and stroke. Flatten it, build CPU-side fan and strip geometry with an anti-aliasing fringe, then render it with a three-pass stencil algorithm and a stroke-mask fragment shader.
**Files Touched**: 12 (Drawer.kt, ShapeContour.kt, Segment2D.kt, Expansion.kt, QualityPolygonDrawer.kt, QualityLineDrawer.kt, ExpansionDrawer.kt, ShaderGeneratorsGLCommon.kt, DriverGL3.kt, plus DrawStyle.kt, PerformanceLineDrawer.kt and CircleDrawer.kt for the alternate paths and the side stop)

All paths are relative to the `frameworks/openrndr/` submodule root. Line numbers refer to the commit recorded in `notes/SUBMODULE-PINS.md`.

## User Code

```kotlin
application {
    configure { width = 800; height = 600 }   // default RenderTarget has a depth+stencil buffer
    program {
        val c = contour {
            moveTo(100.0, 100.0)
            curveTo(300.0, 20.0, 500.0, 180.0, 700.0, 100.0)   // cubic
            lineTo(400.0, 500.0)
            close()
        }
        extend {
            drawer.fill = ColorRGBa.PINK
            drawer.stroke = ColorRGBa.BLACK
            drawer.strokeWeight = 6.0
            drawer.contour(c)           // the call being traced
        }
    }
}
```

## Call Stack

### 1. Entry point: `Drawer.contour()`
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Drawer.kt:873-919`

```kotlin
fun contour(contour: ShapeContour) {
    val distanceTolerance = 0.5 / (modelViewScaling * log2(strokeWeight).coerceAtLeast(1.0))
    val fringeWidth = 1.0 / modelViewScaling
    if (abs(modelViewScaling) < 1E-6) {
        return
    }

    if (RenderTarget.active.hasStencilBuffer) {
        if (drawStyle.fill != null && contour.closed) {
            val apc = contour.adaptivePositionsAndCorners(distanceTolerance)
            ...
            qualityPolygonDrawer.drawPolygon(context, drawStyle, ap, ac, fringeWidth)
        }
        if (drawStyle.stroke != null && drawStyle.strokeWeight > 1E-4) {
            when (drawStyle.quality) {
                DrawQuality.PERFORMANCE -> ... fastLineDrawer.drawLineLoops(...)   // :891-902
                DrawQuality.QUALITY -> { ... qualityLineDrawer.drawLineLoops(...) } // :905-912
```

**What happens**:
- `modelViewScaling` is the scale of the current model-view matrix. Both flattening tolerance and AA fringe width are derived from it, so curves and edges stay about one device pixel wide under zoom. `distanceTolerance` also tightens as `strokeWeight` grows (the `log2(strokeWeight)` term), which keeps thick strokes smooth.
- `shape()` (`Drawer.kt:815-856`) uses the identical formulas on :816-817 and the same stencil requirement at :822. `contour()` is the single-contour variant.
- Fill runs only if `fill != null && contour.closed` (:881). Stroke runs if `stroke != null` and weight > 1E-4 (:889), and branches on `drawStyle.quality`.
- Without a stencil attachment it throws (:917). `shape()` does the same at :854.
- **Fill is drawn first, then stroke.** The two are independent draw calls that flatten the contour twice.
- The PERFORMANCE branch is `fastLineDrawer`. The `closed` switch at :891-903 calls `drawLineLoops` in both arms, so open contours are drawn as loops in PERFORMANCE mode. Verify before relying on that behaviour.

---

### 2. Adaptive flattening with corner flags
**File:** `openrndr-shape/src/commonMain/kotlin/org/openrndr/shape/ShapeContour.kt:255-278`

```kotlin
for (segment in this.segments) {
    val samples = segment.adaptivePositions(distanceTolerance)
    val lastSampleIndex = samples.size - 1
    samples.forEachIndexed { index, it ->
        val last = adaptivePoints.lastOrNull()
        if (last == null || last.squaredDistanceTo(it) > 0.0) {
            adaptivePoints.add(it)
            if (index == 0 || index == lastSampleIndex) {
                corners.add(segment.corner)
            } else {
                corners.add(false)
            }
```

**File:** `openrndr-shape/src/commonMain/kotlin/org/openrndr/shape/Segment2D.kt:164-172`

```kotlin
fun adaptivePositionsWithT(distanceTolerance: Double = 0.5): List<Pair<T, Double>> = when (control.size) {
    0 -> listOf(start to 0.0, end to 1.0)
    1 -> BezierQuadraticSamplerT<T>().apply { this.distanceTolerance = distanceTolerance }
        .sample(start, control[0], end)
    2 -> BezierCubicSamplerT<T>().apply { this.distanceTolerance = distanceTolerance }
        .sample(start, control[0], control[1], end)
    else -> throw RuntimeException("unsupported number of control points")
}
```

**What happens**:
- Each segment is flattened by an adaptive Bézier subdivider (the quadratic and cubic samplers). A line segment returns just its two endpoints.
- Output is `Pair<List<Vector2>, List<Boolean>>`. The boolean marks a "corner". Corners are flagged only at the first and last sample of a segment, and only if `segment.corner` is true (:269-273). Interior samples are always smooth.
- Duplicate consecutive points are dropped (:267), so a segment's end point is not repeated at the next segment's start. The `corner` flag is carried on the segment, so it is not derived geometrically. The user's `curveTo` to `lineTo` junction is a corner only if the segment says so.
- For a closed contour the final point equals the first (see step 3, which drops it).

---

### 3. Build `Path` and `PathPoint`
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/Expansion.kt:361-399` (`fromLineStrip` :361, `fromLineLoops` :387), `PathPoint` at :784-804, `prepare` at :488-520

```kotlin
val drop = closed && segments.first().squaredDistanceTo(segments.last()) < 10E-6
val path = segments.mapIndexed { index, it ->
    PathPoint().apply { x = it.x; y = it.y; flags = if (corners[index]) CORNER else 0 }
}.dropLast(if (drop) 1 else 0)
...
class PathPoint {
    var x, y, dx, dy, length, dmx, dmy: Double;  var flags: Int = 0
    companion object { CORNER = 0x01; LEFT = 0x02; BEVEL = 0x04; INNER_BEVEL = 0x08 }
```

**What happens**:
- The stroke path uses `fromLineStrip(points, corners, closed=true)`, which drops the closing duplicate only if it matches the start (:371).
- The fill path uses `fromLineLoops`, which unconditionally does `.dropLast(1)` (:394). It assumes the loop is already closed with a repeated endpoint.
- Each point becomes a mutable `PathPoint` carrying position, outgoing direction (`dx`,`dy`), segment length, averaged miter vector (`dmx`,`dmy`) and a flag bitset. The seed flag is only `CORNER`.
- `prepare` (:488-520) fills in `dx`,`dy`,`length` as the normalized direction to the next point. It `require`s no consecutive duplicate points (:503) and throws otherwise.

---

### 4. Join classification: `calculateJoins`
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/Expansion.kt:402-486`

```kotlin
val cross = p1.dx * p0.dy - p0.dx * p1.dy
if (cross > 0.0) { nleft += 1; p1.flags = p1.flags or LEFT }
val dot = p0.dx * p1.dx + p0.dy * p1.dy
turnSum += atan2(cross, dot)
...
if (p1.flags and CORNER != 0) {
    if (dmr2 * miterLimit * miterLimit < 1.0f || lineJoin === LineJoin.BEVEL || lineJoin === LineJoin.ROUND) {
        p1.flags = p1.flags or BEVEL
...
val sameSignedTurns = nleft == points.size || nleft == 0
val windsOnce = abs(abs(turnSum) - 2.0 * PI) < 1E-2
convex = sameSignedTurns && windsOnce
```

**What happens**:
- Per vertex it computes the averaged normal (the miter vector `dmx`,`dmy`), a LEFT flag from the cross product, `INNER_BEVEL` when the adjacent segments are too short for a clean inner miter (:444-447), and `BEVEL` when the miter exceeds `miterLimit` or the style is BEVEL/ROUND (:450-459).
- The comment at :426-429 notes this is the NanoVG algorithm with one change. NanoVG clamps the miter scale at 600, which makes very sharp joins shrink back toward the vertex. openrndr removed the clamp and bevels those joins instead, which is why smooth non-corner vertices also get a bevel fallback (:454-459).
- `convex` combines the same-sign turn test with a turning-number check (`|Σ turn| = 2π`) at :483-485. The comment at :471-482 explains why. The sign test alone misclassifies CW polygons (the openrndr default) as non-convex, and it misclassifies a pentagram as convex. A convex flag lets the fill skip stenciling (step 8).
- `convex` is a field on `Path`. `expandFill` forces it to false when there is more than one contour (:655-657).

---

### 5. Stroke expansion: `expandStroke`
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/Expansion.kt:522-641`. Helpers: `bevelTriangle` :82-92, `bevelJoin` :98-185, `roundJoin` :187-255, caps :257-328, `addVertex` :333-350.

```kotlin
val weight = strokeWeight + fringeWidth * 1.0            // :529
...
// -- middle
for (j in start until end) {
    offset += p0.length
    if (p1.flags and (BEVEL or INNER_BEVEL) != 0) {
        if (lineJoin === LineJoin.ROUND) expansion.roundJoin(...)
        else expansion.bevelJoin(p0, p1, weight, weight, 0.0, 1.0, offset, aa)
    } else {
        expansion.addVertex(p1.x + p1.dmx * weight, p1.y + p1.dmy * weight, 0.0, 1.0, offset)
        expansion.addVertex(p1.x - p1.dmx * weight, p1.y - p1.dmy * weight, 1.0, 1.0, offset)
    }
```

```kotlin
fun addVertex(x: Double, y: Double, u: Double, v: Double, offset: Double) {
    ...
    fb[bufferPosition++] = x.toFloat(); y; u; v; offset.toFloat()   // 5 floats per vertex
```

**What happens**:
- The caller (`QualityLineDrawer.drawLineLoops`, step 7) passes `strokeWeight / 2`. `weight` is the half-width plus a full fringe width.
- The output is a **triangle strip** of vertex pairs, left and right of the centerline, in a `FloatArray` of 5 floats per vertex: `x, y, u, v, offset`.
- `u` runs 0 to 1 across the stroke width. `v` is the AA fade along the stroke (1.0 along the body, 0.0 at butt-cap ends). `offset` is the arc length so far, exposed to shade styles as `contourPosition`.
- Joins insert extra vertices into the same strip. `bevelJoin` repeats vertices to create degenerate triangles. `bevelTriangle` (:82-92) gives the bevel its own u/v so the bevel edge is anti-aliased like a butt cap. Without it the fade would smear back to the inner miter point.
- Open strokes add caps. BUTT and SQUARE share `buttCapStart/End` and differ only in the offset `d` (:579-580, :632-633). ROUND uses `roundCapStart/End` (:287-328). Caps are skipped for closed paths, which instead repeat vertices 0 and 1 to close the loop (:616-621).
- Buffer size is pre-computed from `nbevel` (:541-556). `curveDivs` (:806-809) chooses round-join and round-cap step counts from `tessTol = 0.1 * fringeWidth`.

---

### 6. Fill expansion: `expandFill`
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/Expansion.kt:643-781`. `ExpansionType` enum at :23-28.

```kotlin
val woff = 0.5 * fringeWidth
...
fill.addVertex(p1.x + p1.dmx * woff, p1.y + p1.dmy * woff, 0.5, 1.0, pathOffset)  // :700
...
// Create only half a fringe for convex shapes so that
// the shape can be rendered without stenciling.
if (convex) {
    lw = woff    // This should generate the same vertex as fill inset above.
    lu = 0.5    // Set outline fade at middle.
}
```

**What happens**:
- For each contour it builds a **FILL** expansion: the polygon outline inset by half a fringe (`woff`), with bevel points emitting two vertices (:684-698). With `fringeWidth == 0` it uses the raw points (:709-713).
- It then builds a **FRINGE** expansion (:718-773) per contour. This is a closed strip from `+woff` outside to `-woff` inside (`lw = weight + woff`, `rw = weight - woff`) with `u` 0 to 1. The fragment shader fades alpha across `u` using the same `strokeMask`.
- For convex shapes the outer half of the fringe is dropped and `lu = 0.5` makes the fade start at the middle. The fill covers the inside, and the fringe adds a half-pixel feather outside.
- The returned `List<Expansion>` has FILL entries first, then FRINGE entries. It is a polygon outline, not triangles. Fan conversion happens at upload time (step 8).
- Neither `ExpansionType.STROKE` nor `SKIP` appears in the fill path.

---

### 7. The two drawers that bind it together
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/QualityPolygonDrawer.kt:28-43`

```kotlin
val path = Path.fromLineLoops(loops, corners)
val alpha = drawStyle.stroke?.alpha ?: 0.0
val fw = if (drawStyle.smooth) {
    fringeWidth * (1.0 - alpha)
} else 0.0
val fillExpansions = path.expandFill(fw, fw, LineJoin.BEVEL, 2.4)
expansionDrawer.renderFill(drawContext, drawStyle, fillExpansions, path.convex, fw)
```

**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/QualityLineDrawer.kt:95-114`

```kotlin
val path = Path.fromLineStrip(it, corners[index], true)
path.expandStroke(
    effectiveFringeWidth,
    drawStyle.strokeWeight / 2.0,
    drawStyle.lineCap, drawStyle.lineJoin, drawStyle.miterLimit
)
...
expansionDrawer.renderStrokes(drawContext, drawStyle, expansions, effectiveFringeWidth)
```

**What happens**:
- The fill drawer shrinks its fringe by `(1 - stroke.alpha)`. A fully opaque stroke covers the fill edge anyway, so the fill needs no feather there. Fill expansion hard-codes `LineJoin.BEVEL` and miter limit 2.4, so fills ignore the user's `lineJoin`.
- Both drawers set `fw = 0` if `drawStyle.smooth` is false, which disables AA by removing the fringe.
- Each drawer owns its own `ExpansionDrawer`, hence its own shader manager and vertex buffers.
- `drawLineStrips` (:29-48) is the open-path twin of `drawLineLoops`, with the same pipeline.

---

### 8. Upload: `toCommand` and `renderFill`
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/ExpansionDrawer.kt:365-419` (vertex format :32-36, `renderFill` :501-520)

```kotlin
val vertexFormat = vertexFormat {
    position(2)
    textureCoordinate(2)
    attribute("vertexOffset", VertexElementType.FLOAT32)
}
...
// FILL: fan expanded to a plain triangle list
for (i in 1 until expansion.vertexCount - 1) {
    writeVertex(0); writeVertex(i); writeVertex(i + 1)
}
...
// STROKE / FRINGE: strip with leading and trailing degenerate vertices
w.write(expansion.fb, expansion.bufferStart, vertexSize)                    // leading
w.write(expansion.fb, expansion.bufferStart, expansion.bufferPosition - expansion.bufferStart)
w.write(expansion.fb, expansion.bufferStart + vertexSize * (expansion.vertexCount - 1), vertexSize) // trailing
```

**What happens**:
- Vertex layout is `position(2) + textureCoordinate(2) + vertexOffset`, which is the 5-float layout from `addVertex`.
- A FILL expansion becomes a triangle fan from vertex 0, expanded into an explicit `TRIANGLES` list of `(0, i, i+1)` with `(n-2)*3` vertices (:373, :385-389). It is not triangulated, so a concave polygon produces overlapping or wrongly-oriented triangles. That is why the stencil pass exists.
- STROKE and FRINGE are written as strips with the first and last vertex duplicated (`vertexCount + 2`, :395, :404-410). The duplicates let several strips share one buffer and one draw call without connecting.
- `toCommands` (:428-440) accumulates vertex offsets across expansions and uploads once. Small draws rotate through `fewVertices` (multi-buffered), and large ones use the 4M-vertex `manyVertices` buffer (:447-454).
- `renderFill` picks the path (:515-519). `convex` goes to `renderConvexFillCommands`, otherwise `renderFillCommands`.
- **Convex path** (`renderConvexFillCommands`, :189-229): no stencil. It draws the FILL fans as `TRIANGLES` with `strokeFillFactor = 1.0`, then the FRINGE strips as `TRIANGLE_STRIP`, in one pass.

---

### 9. Non-convex fill: three stencil passes, then stroke
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/ExpansionDrawer.kt:231-363` (`renderFillCommands`)

```kotlin
// -- pass 1 : draw fill shapes in stencil only
localStyle.frontStencil.stencilOp(KEEP, KEEP, INCREASE_WRAP)    // :272-276
localStyle.backStencil.stencilOp(KEEP, KEEP, DECREASE_WRAP)     // :277-281
localStyle.channelWriteMask = ChannelMask.NONE                  // :285
localStyle.cullTestPass = CullTestPass.ALWAYS                   // :286
...
// -- pass 2: draw anti-aliased fringes   (:305-328)
shader.uniform("strokeThr", 0.0f)
localStyle.stencil.stencilFunc(StencilTest.EQUAL, 0x00, 0xff)
...
// -- pass 3: fill in stenciled area in pass 1   (:331-358)
localStyle.stencil.stencilFunc(StencilTest.NOT_EQUAL, 0x0, 0xff)
localStyle.stencil.stencilTestMask = 0x1
localStyle.stencil.stencilOp(ZERO, ZERO, ZERO)
... six vertices of the (minX..maxX, minY..maxY) cover quad ...
Driver.instance.drawVertexBuffer(shader, listOf(quad), DrawPrimitive.TRIANGLES, 0, 6, verticesPerPatch = 0)
```

**What happens**:
- **Pass 1**: color writes off, culling off. The fan triangles increment the stencil for front-facing and decrement for back-facing triangles. This is the classic winding-number stencil, and the non-zero rule falls out of it.
- **Pass 2**: color writes on. FRINGE strips are drawn only where `stencil == 0`, so the feather appears only outside the shape. The shader draws these with `strokeThr = 0`.
- **Pass 3**: a bounding-box quad is drawn where the stencil test is NOT_EQUAL 0 (fill color via `strokeFillFactor = 1`). All stencil ops are `ZERO`, so this pass also cleans up the stencil for the next draw.
- Note on pass 3: `stencilTestMask = 0x1` is set after `stencilFunc(..., 0xff)` and is not reset (:334-335), and `setState` passes it straight to `glStencilFuncSeparate` (`DriverGL3.kt:1538-1543`). So pass 3 tests only the low bit. A pixel whose wrapped winding count is 2 would be treated as outside. This looks like an even-odd rule, not the non-zero rule pass 1 suggests, and it differs from the NanoVG mask of 0xff. Verify with a test before relying on non-zero semantics.
- Only `bounds` for `commands[0]` is uploaded (:261-265), while the cover quad uses the union of all commands.

**Strokes**: `renderStrokeCommandsInterleaved`, same file `:120-187` (called from `renderStrokes`, :477-490)

```kotlin
shader.uniform("strokeMult", (drawStyle.strokeWeight * 0.5 + fs * 0.5) / (fs))   // :136
// -- pre
shader.uniform("strokeThr", 1.0f - 0.5f / 255.0f)                                // :142
localStyle.stencil.stencilFunc(StencilTest.EQUAL, 0x00, 0xff)
localStyle.stencil.stencilOp(KEEP, KEEP, INCREASE)                               // :143-144
... TRIANGLE_STRIP ...
// -- anti-aliased
shader.uniform("strokeThr", 0.0f)                                                // :156
localStyle.stencil.stencilOp(KEEP, KEEP, KEEP)
... TRIANGLE_STRIP ...
// -- reset stencil   (color mask off, ALWAYS, ZERO)                             // :170-181
```

- Stroke also uses three draws, again after NanoVG. (a) Draw only the fully opaque core of the stroke (`strokeThr` just under 1.0, so nearly everything with alpha < 1 is discarded) and increment the stencil, which prevents overlapping segments and joins from double-blending. (b) Draw the AA feather where `stencil == 0`. (c) Zero the stencil with colour writes off.
- `strokeMult = (w*0.5 + fs*0.5) / fs` widens the opaque core so the fade is only about one fringe wide.
- All strokes of the call share one command list, one buffer, and a single draw of `vertexCount` vertices (:134, :146-153). The non-interleaved `renderStrokeCommands` (:50-118) is the same algorithm per command, with `strokeThr = -1.0` in the AA pass. It is not reached from `renderStrokes`.

---

### 10. Fragment and vertex shaders
**File:** `openrndr-gl-common/src/commonMain/kotlin/ShaderGeneratorsGLCommon.kt:587-646` (fragment), `:648-683` (vertex)

```glsl
float strokeMask() {
    return min(1.0, (1.0-abs(v_ftcoord.x*2.0-1.0))*strokeMult) * min(1.0, v_ftcoord.y);
}
void main(void) {
    float strokeAlpha = strokeMask();
    vec4 x_stroke = u_stroke;
    vec4 x_fill = u_fill;
    ...
    vec4 color = mix(x_stroke, x_fill, strokeFillFactor)  * vec4(1.0, 1.0, 1.0, strokeAlpha);
    if (strokeAlpha < strokeThr) { discard; }
    ...
    final.rgb *= final.a;     // premultiplied output
```

Vertex shader essentials (:667-682): `v_ftcoord = a_texCoord0; v_objectPosition = vec3(a_position, 0.0); ... gl_Position = v_clipPosition;`. The shader is generated as a string per `ShadeStructure`, so user `ShadeStyle` code is spliced in at `fragmentTransform`.

**What happens**:
- One shader serves fill, fringe and stroke. `v_ftcoord.x` is the across coordinate `u` and `.y` is the along-fade `v` from step 5. `strokeMask` peaks at `u = 0.5` and falls to 0 at the stroke edges, scaled by `strokeMult` so the plateau is wide. `min(1, v)` fades the butt-cap ends.
- Fill vertices have `u = 0.5, v = 1.0`, so they evaluate to 1.0 at full `strokeMult`. FRINGE vertices fade from `u = 0.5` (inside) to `u = 1.0` (outside).
- `strokeFillFactor` picks `u_stroke` (0.0) or `u_fill` (1.0). `strokeThr` is the per-pass discard threshold (just below 1 for the stroke core pass, 0 for AA passes, -1 to disable).
- Output is premultiplied alpha. `contourPosition = va_vertexOffset` and `bounds` feed `ShadeStyle` (:618-624).
- The generator is selected through the `Driver`: `DriverGL3.kt:692` sets `override val shaderGenerators: ShaderGenerators = ShaderGeneratorsGLCommon()`, and `ExpansionDrawer.kt:26-30` binds `expansionVertexShader`/`expansionFragmentShader` via `ShadeStyleManager.fromGenerators`.

---

### 11. GL state and the draw call
**File:** `openrndr-jvm/openrndr-gl3/src/commonJvmMain/kotlin/org/openrndr/internal/gl3/DriverGL3.kt:1484-1584` (`setState`), `:1005-1047` (`drawVertexBuffer`)

```kotlin
if (dirty || cached.stencil != drawStyle.stencil || cached.backStencil != ... ) {
    if (drawStyle.frontStencil === drawStyle.backStencil) {
        ... glStencilFuncSeparate(GL_FRONT_AND_BACK, ...)   // :1538
    } else {
        ... glStencilFuncSeparate(GL_FRONT, ...) / (GL_BACK, ...)    // :1559-1570
        glStencilOpSeparate(GL_FRONT, ...) / (GL_BACK, ...)          // :1571-1582
        glStencilMaskSeparate(GL_FRONT, ...) / (GL_BACK, ...)        // :1583-1584
...
glColorMask(red, green, blue, alpha)                          // :1513
...
CullTestPass.ALWAYS -> glDisable(GL_CULL_FACE)                // :1636-1639
...
glBindVertexArray(vao)
glDrawArrays(drawPrimitive.glType(), vertexOffset, vertexCount)   // :1047
```

**What happens**:
- `setState` diffs against a per-context cached `DrawStyle` and only issues GL calls for changed groups (clip, color mask, depth, stencil, cull, blend). Pass 1 relies on `frontStencil !== backStencil` object identity to select the separate-face branch (:1533, :1555-1584). Passes 2 and 3 set `frontStencil = backStencil = stencil` (:302-303), taking the `GL_FRONT_AND_BACK` branch. Note that this branch calls `glStencilMaskSeparate` too, so the write mask is part of the cached state.
- `drawVertexBuffer` finds or creates a VAO for `(contextID, program, vertex buffer ids)` (:1029-1036), binds it and calls `glDrawArrays` (:1047). Each pass issues its own draw call, so a closed, filled and stroked non-convex contour costs 3 draws for the fill plus 3 for the stroke.
- `GL_FRAMEBUFFER_SRGB` is enabled on desktop GL at the start of `setState` (:1485-1487).

---

### 12. Side stop: circles take a completely different path
**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/CircleDrawer.kt:145-200`

```kotlin
Driver.instance.drawInstances(
    shader, listOf(vertices),
    instanceAttributes + (drawStyle.shadeStyle?.attributes.orEmpty()),
    DrawPrimitive.TRIANGLES, 0, 6, 0, count, verticesPerPatch = 0
)
```

**Related**: per-instance formats in `openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Batches.kt:26-35` (`drawStyleFormat`: fill, stroke, strokeWeight; `circleFormat`: offset vec3, radius vec2). Shaders in `openrndr-gl-common/src/commonMain/kotlin/ShaderGeneratorsGLCommon.kt:358-383` (fragment) and `:386-` (vertex).

```glsl
float wd = fwidth(length(va_texCoord0 - vec2(0.0)));
float d = length(va_texCoord0 - vec2(0.5)) * 2.0;
float or = smoothstep(0.0, wd * smoothFactor, 1.0 - d);          // :368-373
...
vec2 effectiveRadius = i_radius.xy + vec2(1.25 / u_contentScale) / (u_modelViewScalingFactor);   // :407
```

**What happens**: a circle is one instanced unit quad (6 vertices, `count` instances). The fragment shader computes the distance field analytically and anti-aliases with `smoothstep(0, fwidth*3, ...)` on the outer edge and inner edge, so fill and stroke come from one draw. The vertex shader grows the quad by `1.25 / contentScale` so the AA ramp is not clipped. There is no contour, no stencil, no CPU geometry. It is the model a Flux path/shape drawer should use for simple primitives (circle, rect, point).

## Data Flow Diagram

```
drawer.contour(c)    c: ShapeContour (Segment2D list: line / quad / cubic)
    │   modelViewScaling → distanceTolerance, fringeWidth
    ▼
┌─────────────────────────────────────────────────────────────┐
│ ShapeContour.adaptivePositionsAndCorners(tol)               │
│ → (List<Vector2>, List<Boolean> corners)                    │
└─────────────────────────────────────────────────────────────┘
    │  (done twice: once for fill, once for stroke)
    ├───────────── fill branch ───────────┐    ┌──── stroke branch ───┐
    ▼                                      │   ▼                      │
┌───────────────────────────┐              │ ┌──────────────────────┐ │
│ Path.fromLineLoops        │              │ │ Path.fromLineStrip   │ │
│ → Path{PathPoint[]}       │              │ │ → Path{PathPoint[]}  │ │
│ prepare + calculateJoins  │              │ │ prepare + calcJoins  │ │
│ → flags, convex           │              │ │ → flags              │ │
└───────────────────────────┘              │ └──────────────────────┘ │
    ▼                                      │   ▼                      │
┌───────────────────────────┐              │ ┌──────────────────────┐ │
│ expandFill(fw, fw, BEVEL) │              │ │ expandStroke(...)    │ │
│ → FILL polygon (inset)    │              │ │ → STROKE strip with  │ │
│ + FRINGE strip            │              │ │   joins/caps         │ │
│   FloatArray 5 f/vertex   │              │ │   FloatArray 5 f/vtx │ │
└───────────────────────────┘              │ └──────────────────────┘ │
    ▼                                      │   ▼                      │
┌───────────────────────────────────────────┴─────────────────────────┴┐
│ ExpansionDrawer.toCommands → VertexBuffer (pos2, uv2, offset)        │
│   FILL: fan → TRIANGLES (0,i,i+1)                                    │
│   FRINGE/STROKE: TRIANGLE_STRIP + degenerate lead/trail vertices     │
└──────────────────────────────────────────────────────────────────────┘
    │
    ├─ convex fill: draw FILL (TRIANGLES) + FRINGE (STRIP), no stencil
    ├─ concave fill: pass1 stencil INC/DEC_WRAP, colour off
    │                pass2 fringe @ stencil==0
    │                pass3 cover quad @ stencil!=0, zero stencil
    └─ stroke: pass A core (strokeThr≈1) INCREASE@==0
               pass B AA fringe (strokeThr 0) @==0
               pass C clear stencil, colour off
    ▼
┌──────────────────────────────────────────────────────────────┐
│ Driver.setState(drawStyle)  (diffed vs cached state)         │
│   glStencilFunc/OpSeparate, glColorMask, glDisable(CULL_FACE)│
│ Driver.drawVertexBuffer → VAO bind → glDrawArrays            │
└──────────────────────────────────────────────────────────────┘
    ▼
Expansion vertex shader → fragment shader:
  strokeMask(u,v)*strokeMult, mix(stroke,fill,strokeFillFactor),
  discard if alpha < strokeThr, premultiplied output
    ▼
Framebuffer pixels (stencil returned to 0)
```

## Key Observations

1. **No triangulator in the draw path.** `openrndr-shape/.../Triangulator.kt:23` defines `triangulate`. Its only use is `Shape.triangulation` (`openrndr-shape/.../Shape.kt:108-111`, with a reset at :142), plus a test in `openrndr-ktessellation`. No drawer calls it. Fill is a fan plus stencil, so CPU cost is O(n) per draw with no ear clipping or monotone decomposition.
2. **This is NanoVG's design.** It uses a fan, a winding-number stencil, an AA fringe strip and a stroke-core pass. The code even keeps NanoVG's `strokeThr = 1 - 0.5/255`, `strokeMult` formula, `2.4` miter limit and bevel/inner-bevel flags. It departs in a few places: no miter-scale clamp (:426-429), a separate `bevelTriangle` for bevel AA (:82-92), and the turning-number convexity test (:471-485).
3. **Convex fast path.** One flag, computed on the CPU from turn signs and total turning, removes three of six draws and the stencil requirement for that shape. A concave fill needs the stencil attachment to run, and `contour()` and `shape()` both throw without one (`Drawer.kt:917`, `:854`).
4. **Pass 3 uses `stencilTestMask = 0x1`** (`ExpansionDrawer.kt:335`), which gives parity-like behaviour even though the earlier passes accumulate a winding number with wrap ops. This is a potential behavioural difference from NanoVG that was not tested at runtime.
5. **AA is geometric, not MSAA.** Edges feather over a fringe whose width is `1 / modelViewScaling`, so it tracks device pixels across zoom levels. `drawStyle.smooth = false` sets `fw = 0` and removes the fringe. Fill reduces its own fringe by the stroke alpha.
6. **Expansion happens on the CPU on every call.** There is no caching of flattened or expanded geometry between frames. The contour is flattened twice (fill and stroke), and strokes and fills each run `prepare` and `calculateJoins` separately.
7. **State churn.** Each stencil pass is a full `setState` plus a draw, in a mutable `DrawStyle` that the code edits in place (`localStyle = drawStyle`, :133, :247). The code restores `stencilTest = DISABLED` at the end (:183, :361), but a missed reset would leak into later draws.
8. **Joins and caps.** `LineJoin` is only MITER, BEVEL and ROUND (`draw/DrawStyle.kt:12-16`). Round joins and caps use a fan-style vertex pattern in the same strip (`roundJoin` :187-255). Miter is implemented by *not* flagging BEVEL below the miter limit.
9. **Quality switch.** `DrawQuality` has QUALITY and PERFORMANCE (`draw/DrawStyle.kt:411-414`), and the default is QUALITY (:442). PERFORMANCE strokes use `DrawPrimitive.LINES` (`internal/PerformanceLineDrawer.kt:79, 126, 172, 215`), which have no fringe and no joins, and so no AA. The fill still goes through the quality path.
10. **Unusual encoding.** `PathPoint.flags` is a bitset mutated in place by `calculateJoins`. `Expansion.addVertex` silently drops NaN vertices (:334-336), and `bevelJoin` returns early on NaN inputs (:109-110), which hides bad geometry instead of failing. `prepare` is the only place that hard-fails (duplicate points, :503).
11. **Circles bypass all of this.** An analytic SDF in an instanced quad shader gives resolution-independent AA and one draw call, where the contour path needs about six.

## Implications for Rust Framework

### Adopt
- The **fringe-width-from-scale** idea: derive both flatten tolerance and AA width from the effective pixel size, so geometry is correct at any zoom and DPI.
- The **per-primitive split**: analytic instanced quads for circles, rects and points, and the expansion pipeline only for arbitrary paths.
- A single **vertex format** shared across fill, fringe and stroke (`pos, uv, arc-length`), with the fragment shader reading `uv` to do all AA. This keeps one pipeline and one shader per path draw.
- The **convex fast path** with a turning-number check, not just a sign check (the openrndr comment at :471-482 is a useful bug list).
- Exposing **arc length (`vertexOffset`)** to the shader for dashing and gradients along strokes.

### Modify
- Replace in-place mutable `DrawStyle` and `PathPoint` flags with per-pass **immutable pipeline descriptors** (`wgpu::RenderPipeline` with `DepthStencilState` and `StencilFaceState` front/back). Pass 1 needs separate front/back ops (`IncrementWrap` / `DecrementWrap`), which wgpu supports directly. Render pipelines are built ahead of time, so the six stencil states become six cached pipelines rather than runtime state diffs.
- wgpu has no `glColorMask` toggle at draw time. Pass 1 uses a pipeline with `write_mask: ColorWrites::empty()`.
- Decide on even-odd or non-zero explicitly, and expose it as an API option (`FillRule`), with stencil `read_mask` as a pipeline property.
- Cache the expanded geometry (key on contour id + scale bucket + style) instead of re-expanding every frame. Alternatively, keep persistent mapped buffers and let callers hold a prepared `PathMesh`.
- Batch many contours into one buffer per pass. The interleaved stroke path already shows the pattern for strokes (one draw for N expansions). Do the same for fills.
- Make the stencil requirement a **type-level fact**: a `RenderTarget` with a stencil format, or an internal one allocated lazily by the path renderer, not a runtime `error()`.
- Replace NaN-swallowing with validation at the `PathBuilder` boundary (return `Result`), and make duplicate-point handling total rather than a `require`.
- On web and mobile, check that WebGPU's `Depth24PlusStencil8` or `Depth32FloatStencil8` is available, since stencil precision is only 8 bits and the wrap ops depend on it.

### Avoid
- Flattening twice per call, and fill code that bakes in `LineJoin::Bevel` and miter 2.4 regardless of style.
- A global mutable "current style" that passes edit and restore by hand.
- Per-vertex branches in the shader for `strokeThr`. Use separate pipelines or specialization constants for the passes instead of a runtime discard threshold uniform.
- Relying on 8-bit stencil wrap for very complex self-overlapping paths (overflow at 256 layers) without documenting the limit.
- Silent `drawLineLoops` fallback for open contours in a fast path (see step 1).

### API Sketch
```rust
pub struct PathStyle {
    pub fill: Option<LinearRgba>,
    pub stroke: Option<LinearRgba>,
    pub stroke_weight: f32,
    pub join: LineJoin,            // Miter | Bevel | Round
    pub cap: LineCap,
    pub miter_limit: f32,
    pub fill_rule: FillRule,       // NonZero | EvenOdd
    pub antialias: bool,
}

/// CPU-side result of flattening + expansion; cacheable.
pub struct PathMesh {
    fill_fan: Vec<PathVertex>,     // triangle list, 0,i,i+1
    fringe: Vec<PathVertex>,       // strip with degenerates
    stroke: Vec<PathVertex>,
    bounds: Rect,
    convex: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct PathVertex { pos: [f32; 2], uv: [f32; 2], arc: f32 }

impl PathRenderer {
    pub fn prepare(&mut self, c: &Contour, style: &PathStyle, scale: f32) -> PathMesh;
    pub fn draw<'p>(&'p self, pass: &mut wgpu::RenderPass<'p>, mesh: &'p PathMesh, style: &PathStyle) {
        if mesh.convex {
            pass.set_pipeline(&self.convex_fill);           // no stencil
            // fan + fringe
        } else {
            pass.set_pipeline(&self.stencil_inc_dec_wrap);  // color write mask empty
            pass.set_pipeline(&self.fringe_where_zero);
            pass.set_pipeline(&self.cover_not_zero_and_clear);
        }
        // stroke: core pass (strokeThr≈1) -> AA pass -> clear
    }
}
```

## Related Documents

- [Rendering Pipeline](../rendering-pipeline.md) — the narrative version of this trace
- [openrndr README](../README.md) — framework overview and entry points
- [Vector graphics theme](../../../themes/vector-graphics/README.md) — openrndr's Shape/ShapeContour data model and boolean operations
- [Rasterization strategies](../../../themes/vector-graphics/rasterization-strategies.md) — how this stencil-and-fringe approach compares with tessellation and coverage rendering

---

*This document is part of the [openrndr study](../README.md).*
