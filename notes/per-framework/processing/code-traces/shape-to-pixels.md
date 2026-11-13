# Code Trace: Processing `beginShape()/vertex()/endShape()` to pixels, Java2D and P2D side by side

> Tracing `beginShape(); vertex(...); bezierVertex(...); endShape(CLOSE)` from user code to pixels, once through `PGraphicsJava2D` and once through `PGraphics2D` (OpenGL).

## Overview

**Framework**: Processing 4 (`frameworks/processing/`, checkout `be0ee8266e07`, 2026-09-25)
**Operation**: A filled and stroked polygon containing one cubic Bézier segment, drawn with the default Java2D renderer and with `P2D`.
**Files Touched**: 12 (`PApplet`, `PConstants`, `PGraphics`, `PGraphicsJava2D`, `PGraphicsOpenGL`, `PGraphics2D`, `PJOGL`, `PGL`, `PShaderOpenGL`, `PSurfaceJOGL`, `LinePath`/`LineStroker`, `PShapeOpenGL`)

All paths below are relative to the submodule root `frameworks/processing/`. Line numbers refer to the commit recorded in `notes/SUBMODULE-PINS.md`.

Processing exposes one drawing API and two rasterizers behind it:

- **Java2D** records a `GeneralPath` and hands it to `Graphics2D`. The JDK owns curve flattening, stroking and antialiasing.
- **P2D** builds exact triangles on the CPU: it flattens curves, runs a GLU tessellator for the fill, and turns strokes into more triangles. It then draws them with `glDrawElements` and relies on MSAA for antialiasing.

## User Code

```java
// Run once with size(400, 400) and once with size(400, 400, P2D).
void setup() {
  size(400, 400);            // or: size(400, 400, P2D);
  smooth(4);
}

void draw() {
  background(240);
  fill(255, 140, 0);
  stroke(30);
  strokeWeight(6);
  strokeJoin(ROUND);
  beginShape();
  vertex(60, 300);
  vertex(120, 80);
  bezierVertex(200, 20, 300, 20, 340, 120);  // cubic: 2 control points + anchor
  vertex(320, 320);
  endShape(CLOSE);
}
```

## Call Stack

### 1. Renderer selection by class name
**File:** `core/src/processing/core/PApplet.java:1729`

```java
public void size(int width, int height, String renderer) {
  if (width != this.width ||
      height != this.height ||
      !renderer.equals(this.renderer)) {
    if (insideSettings("size", width, height, "\"" + renderer + "\"")) {
      this.width = width;
      this.height = height;
      this.renderer = renderer;
    }
  }
}
```

**What happens**: `size()` only records the renderer as a string. The constants in `core/src/processing/core/PConstants.java:60-63` are class names:

```java
String JAVA2D = "processing.awt.PGraphicsJava2D";
String P2D = "processing.opengl.PGraphics2D";
String P3D = "processing.opengl.PGraphics3D";
```

`size(w, h)` with no renderer falls back to `JAVA2D`. Nothing is instantiated yet.

---

### 2. Reflection instantiation
**File:** `core/src/processing/core/PApplet.java:1884`

```java
protected PGraphics makeGraphics(int w, int h,
                                 String renderer, String path,
                                 boolean primary) {
  ...
  try {
    Class<?> rendererClass =
      Thread.currentThread().getContextClassLoader().loadClass(renderer);

    Constructor<?> constructor = rendererClass.getConstructor();
    PGraphics pg = (PGraphics) constructor.newInstance();

    pg.setParent(this);
    pg.setPrimary(primary);
```

**What happens**: The renderer is `loadClass(name)` followed by `getConstructor().newInstance()` (lines 1896-1900). Every renderer is a no-arg `PGraphics` subclass, and the sketch receives it as the base type `g`. The same function backs `createGraphics()`. Lines 1887-1893 refuse an off-screen P2D/P3D buffer when the primary renderer is not GL.

---

### 3. Shared front end: modes are normalised before dispatch
**File:** `core/src/processing/core/PGraphics.java:2911` (ellipse) and `:2684` (rect)

```java
public void ellipse(float a, float b, float c, float d) {
  float x = a; float y = b; float w = c; float h = d;
  if (ellipseMode == CORNERS) {
    w = c - a;
    h = d - b;
  } else if (ellipseMode == RADIUS) { ... }
  ...
  if (w < 0) { x += w; w = -w; }   // undo negative width
  ...
  ellipseImpl(x, y, w, h);
}

protected void rectImpl(float x1, float y1, float x2, float y2) {
  quad(x1, y1,  x2, y1,  x2, y2,  x1, y2);   // :2721-2723
}
```

**What happens**: `ellipse()` and `rect()` (2684-2723) resolve `ellipseMode`/`rectMode` (CORNER, CORNERS, CENTER, RADIUS) and swap negative extents. They then call a protected `*Impl` method with canonical arguments. `rectImpl` defaults to `quad()`, so a renderer that overrides nothing still draws rectangles. The primitives are template methods: the base class owns argument semantics and subclasses own geometry. `beginShape/vertex/endShape` are the open-ended case and are overridden directly in each subclass (steps 4 and 8).

---

## Java2D branch

### 4. `beginShape`: reset the path
**File:** `core/src/processing/awt/PGraphicsJava2D.java:713`

```java
@Override
public void beginShape(int kind) {
  //super.beginShape(kind);
  shape = kind;
  vertexCount = 0;
  curveVertexCount = 0;

  // set gpath to null, because when mixing curves and straight
  // lines, vertexCount will be set back to zero ...
  gpath = null;
  auxPath = null;
}
```

**What happens**: The Java2D renderer does not call `super.beginShape`. State is one `java.awt.geom.GeneralPath` field (`gpath`), plus `auxPath` for contours. `gpath == null` means "no vertex yet", which replaces a `vertexCount == 1` test because curves reset the vertex count.

---

### 5. `vertex` and `bezierVertex` append to the path
**File:** `core/src/processing/awt/PGraphicsJava2D.java:842` and `:1055`

```java
case POLYGON:
  if (gpath == null) {
    gpath = new GeneralPath();
    gpath.moveTo(x, y);
  } else if (breakShape) {
    gpath.moveTo(x, y);
    breakShape = false;
  } else {
    gpath.lineTo(x, y);
  }
  break;
...
public void bezierVertex(float x1, float y1,
                         float x2, float y2,
                         float x3, float y3) {
  bezierVertexCheck();
  gpath.curveTo(x1, y1, x2, y2, x3, y3);
}
```

**What happens**: The first vertex is `moveTo`, later ones are `lineTo`, and a contour break issues another `moveTo`. `bezierVertex` is a direct `curveTo`, so no CPU flattening happens. The curve stays a cubic segment until the JDK rasterizer processes it.

Contours (`beginContour`/`endContour`, :881-916) swap `gpath` and `auxPath`, so a hole is built as a separate path that is appended at the end:

```java
GeneralPath contourPath = auxPath;
auxPath = gpath;
gpath = contourPath;
if (contourPath != null) {  // first contour does not break
  breakShape = true;
}
```

---

### 6. `endShape`: close, merge, draw
**File:** `core/src/processing/awt/PGraphicsJava2D.java:920`

```java
public void endShape(int mode) {
  ...
  if (gpath != null) {  // make sure something has been drawn
    if (shape == POLYGON) {
      if (mode == CLOSE) {
        gpath.closePath();
      }
      if (auxPath != null) {
        gpath.append(auxPath, false);
      }
      drawShape(gpath);
    }
  }
  shape = 0;
}
```

**What happens**: Only `POLYGON` is drawn from a path here. Other kinds (`TRIANGLES`, `QUAD_STRIP`, ...) go through different branches that draw as they receive vertices. The draw is immediate: nothing is retained or batched.

---

### 7. `drawShape`: fill then stroke by the JDK
**File:** `core/src/processing/awt/PGraphicsJava2D.java:1345`

```java
protected void drawShape(Shape s) {
  if (fillGradient) {
    g2.setPaint(fillGradientObject);
    g2.fill(s);
  } else if (fill) {
    g2.setColor(fillColorObject);
    g2.fill(s);
  }
  if (strokeGradient) {
    g2.setPaint(strokeGradientObject);
    g2.draw(s);
  } else if (stroke) {
    g2.setColor(strokeColorObject);
    g2.draw(s);
  }
}
```

**What happens**: Fill and stroke are two separate `Graphics2D` calls on the same `Shape`, in that order, so the stroke is composited over the fill. Pixels end up in the `BufferedImage` behind `g2`.

Stroke state is installed when the user calls `strokeWeight`/`strokeCap`/`strokeJoin` (`strokeImpl`, :2460-2477). The mapping is trivial:

```java
int join = BasicStroke.JOIN_BEVEL;
if (strokeJoin == MITER) {
  join = BasicStroke.JOIN_MITER;
} else if (strokeJoin == ROUND) {
  join = BasicStroke.JOIN_ROUND;
}
strokeObject = new BasicStroke(strokeWeight, cap, join);
g2.setStroke(strokeObject);
```

Antialiasing is a rendering hint set by `handleSmooth()` (:394-430):

```java
g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING,
                    RenderingHints.VALUE_ANTIALIAS_ON);
```

The JDK's scanline rasterizer computes analytic coverage, so edges are antialiased per path, not per sample.

---

## P2D branch

### 8. `beginShape` / `endShape`: collect, tessellate, maybe flush
**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:1914` and `:1930`

```java
public void beginShape(int kind) {
  shape = kind;
  inGeo.clear();
  curveVertexCount = 0;
  breakShape = false;
  defaultEdges = true;
  super.noTexture();           // avoids an early flush
  normalMode = NORMAL_MODE_AUTO;
}

public void endShape(int mode) {
  tessellate(mode);

  if ((flushMode == FLUSH_CONTINUOUSLY) ||
      (flushMode == FLUSH_WHEN_FULL && tessGeo.isFull())) {
    flush();
  } else {
    // pixels array is not up-to-date anymore
    loaded = false;
  }
}
```

**What happens**: `vertex()` and `bezierVertex()` append control points and a per-vertex code (`VERTEX`, `BEZIER_VERTEX`, ...) to the `inGeo` input geometry. Nothing is flattened or drawn until `endShape`. `endShape` tessellates immediately into `tessGeo`, but draws only when `flushMode == FLUSH_CONTINUOUSLY` or the buffer is full. The default is `flushMode = FLUSH_WHEN_FULL` (`:107`), so many shapes are accumulated into one batch per frame, until the batch is full or something forces a flush (e.g. `shape()`, `hint()`, end of frame).

---

### 9. `tessellate`: configure the Tessellator, dispatch by shape kind
**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:2178`

```java
protected void tessellate(int mode) {
  tessellator.setInGeometry(inGeo);
  tessellator.setTessGeometry(tessGeo);
  tessellator.setFill(fill || textureImage != null);
  tessellator.setStroke(stroke);
  tessellator.setStrokeColor(strokeColor);
  tessellator.setStrokeWeight(strokeWeight);
  tessellator.setStrokeCap(strokeCap);
  tessellator.setStrokeJoin(strokeJoin);
  tessellator.setRenderer(this);
  tessellator.setTransform(modelview);
  tessellator.set3D(is3D());
  ...
  } else if (shape == TRIANGLE_FAN) {
    if (stroke && defaultEdges) inGeo.addTriangleFanEdges();
    ...
    tessellator.tessellateTriangleFan();
  ...
  } else if (shape == POLYGON) {
    tessellator.tessellatePolygon(true, mode == CLOSE,
                                  normalMode == NORMAL_MODE_AUTO);
  }
}
```

**What happens**: All draw state is copied into the `Tessellator`, including the current `modelview` (so vertices are transformed on the CPU) and the `is3D()` flag. The fill algorithm is then picked by shape kind, not by geometry: fans, strips, triangles and quads use trivial index generation, and only `POLYGON` goes through GLU. A convex `POLYGON` pays the same GLU cost as a concave one.

---

### 10. Ellipse in GL: a fan sized by screen size
**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:3096` and `:8700`

```java
public void ellipseImpl(float a, float b, float c, float d) {
   beginShape(TRIANGLE_FAN);
   defaultEdges = false;
   normalMode = NORMAL_MODE_SHAPE;
   ...
   inGeo.addEllipse(a, b, c, d, fill, stroke);
   endShape();
}
...
float sx1 = pg.screenX(x, y);
float sy1 = pg.screenY(x, y);
float sx2 = pg.screenX(x + w, y + h);
float sy2 = pg.screenY(x + w, y + h);

int accuracy =
  PApplet.min(MAX_POINT_ACCURACY, PApplet.max(MIN_POINT_ACCURACY,
              (int) (TWO_PI * PApplet.dist(sx1, sy1, sx2, sy2) /
              POINT_ACCURACY_FACTOR)));
```

**What happens**: The vertex count comes from the on-screen diagonal (`addEllipse`, :8709-8717), clamped between min and max, and the points come from sin/cos lookup tables. The tessellator then writes fan indices on the CPU (`tessellateTriangleFan`, :13068-13084) with no GLU:

```java
for (int i = 1; i < in.vertexCount - 1; i++) {
  rawIndices[idx++] = 0;
  rawIndices[idx++] = i;
  rawIndices[idx++] = i + 1;
}
```

A small circle gets few segments and a huge one gets many, so curve flattening is screen-space adaptive for ellipses. The Bézier path (step 11) uses a fixed `bezierDetail` instead.

---

### 11. Arbitrary polygons: GLU fill, CPU curve flattening
**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:13473`

```java
void tessellatePolygon(boolean solid, boolean closed, boolean calcNormals) {
  ...
  if (3 <= nInVert) {
    initGluTess();
    ...
    if (fill) {
      gluTess.beginPolygon();
      if (solid) {
        // Using NONZERO winding rule for solid polygons.
        gluTess.setWindingRule(PGL.TESS_WINDING_NONZERO);
      } else {
        // Using ODD winding rule to generate polygon with holes.
        gluTess.setWindingRule(PGL.TESS_WINDING_ODD);
      }
      gluTess.beginContour();
    }
    ...
      if (code == BEZIER_VERTEX) {
        addBezierVertex(i);
        i += 3;
```

**What happens**: Each input vertex is consumed according to its code. A `BREAK` code ends the current contour and begins another, for both the stroke path and the GLU contour (:13515-13524). The winding rule is NONZERO when `solid` is true and ODD otherwise (:13485-13495). Note that the immediate-mode call at `PGraphicsOpenGL.java:2221` always passes `solid = true`, so `beginShape/endShape` polygons always use NONZERO. The `false` branch is reachable only from retained `PShapeOpenGL` (`core/src/processing/opengl/PShapeOpenGL.java:3738`).

Cubic Béziers are flattened on the CPU by forward differencing (`addBezierVertex`, :13554-13610):

```java
for (int j = 0; j < pg.bezierDetail; j++) {
  x1 += xplot1; xplot1 += xplot2; xplot2 += xplot3;
  y1 += yplot1; yplot1 += yplot2; yplot2 += yplot3;
  ...
  if (fill) {
    double[] vertex = Arrays.copyOf(vertexT, vertexT.length);
    vertex[0] = x1; vertex[1] = y1; vertex[2] = z1;
    gluTess.addVertex(vertex);
  }
  if (stroke) addStrokeVertex(x1, y1, z1, strokeColor, strokeWeight);
}
```

The same flattened points feed both the fill tessellator and the stroke path. Each point allocates a `double[]` (copy of the attribute template), a JVM allocation cost visible on every curve.

The GLU tessellator is lazily created in `initGluTess()` (`:11907-11912`, inside `static protected class Tessellator` at `:11847`) and wrapped by `PJOGL` (`core/src/processing/opengl/PJOGL.java:593-611`):

```java
tess = GLU.gluNewTess();
gluCallback = new GLUCallback();

GLU.gluTessCallback(tess, GLU.GLU_TESS_BEGIN, gluCallback);
GLU.gluTessCallback(tess, GLU.GLU_TESS_END, gluCallback);
GLU.gluTessCallback(tess, GLU.GLU_TESS_VERTEX, gluCallback);
GLU.gluTessCallback(tess, GLU.GLU_TESS_COMBINE, gluCallback);
```

`TessellatorCallback` (:13992-14080) receives GLU's output as primitive runs (fan, strip, triangles) and converts each to a plain triangle index list. For a `TRIANGLE_FAN` run:

```java
case TRIANGLE_FAN:
  indCount = 3 * (vertCount - 2);
  for (int i = 1; i < vertCount - 1; i++) {
    addIndex(0);
    addIndex(i);
    addIndex(i + 1);
```

The COMBINE callback creates new vertices where contours self-intersect, which is why every vertex carries the full attribute tuple (position, colour, normal, texcoord, material).

---

### 12. Strokes become CPU triangles
**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:13890` and `:12627`

```java
void tessellateStrokePath() {
  if (in.edgeCount == 0) return;
  ...
  if (is3D) {
    tessellateEdges3D();
  } else if (is2D) {
    beginNoTex();
    tessellateEdges2D();
    endNoTex();
  }
}
...
void tessellateEdges2D() {
  int nInVert = in.getNumEdgeVertices(false);
  if (noCapsJoins(nInVert)) {
    ...
    for (int i = 0; i <= in.edgeCount - 1; i++) {
      ...
      index = addLineSegment2D(i0, i1, index, false, clamp);
    }
  } else { // full stroking algorithm
    LinePath path = new LinePath(LinePath.WIND_NON_ZERO);
    ...
    tessellateLinePath(path);
  }
}
```

**What happens**: `tessellateEdges2D` has two paths:

- **Fast path**: one quad per segment via `addLineSegment2D` (:12849+). It ignores `EDGE_CLOSE`, and there are no caps or joins, so you see gaps or overlaps at corners.
- **Full path**: builds a `LinePath` and calls `tessellateLinePath`.

The choice is `noCapsJoins` (:12956-12978):

```java
boolean noCapsJoins(int nInVert) {
  if (!accurate2DStrokes) {
    return true;
  } else if (PGL.MAX_CAPS_JOINS_LENGTH <= nInVert) {
    // The line path is too long, so it could make the GLU tess
    // to run out of memory, so full caps and joins are disabled.
    return true;
  } else {
    return noCapsJoins();
  }
}
...
return tess.renderMode == IMMEDIATE &&
       transformScale() * strokeWeight < PGL.MIN_CAPS_JOINS_WEIGHT;
```

The thresholds are `MAX_CAPS_JOINS_LENGTH = 5000` vertices (`core/src/processing/opengl/PGL.java:121`) and `MIN_CAPS_JOINS_WEIGHT = 2f` pixels (`PGL.java:116`). Thin strokes in immediate mode get the quad shortcut. Retained shapes always take the full path. In the sketch above (weight 6, round join), the full path is used.

The full path is `tessellateLinePath` (:13908-13969):

```java
// Tessellates the path given as parameter. This will work only in 2D.
// Based on the opengl stroke hack described here:
// http://wiki.processing.org/w/Stroke_attributes_in_OpenGL
public void tessellateLinePath(LinePath path) {
  ...
  // Make the outline of the stroke from the path
  LinePath strokedPath = LinePath.createStrokedPath(path, strokeWeight,
                                                    cap, join);

  gluTess.beginPolygon();
  ...
  LinePath.PathIterator iter = strokedPath.getPathIterator();
```

`LinePath.createStrokedPath` produces the stroke outline as a new path. The outline is then fed to the same GLU tessellator and becomes ordinary triangles. Inside `LinePath` (`core/src/processing/opengl/LinePath.java:426-434`) the stroker emits fixed-point coordinates that are converted back:

```java
dest.moveTo(S15_16ToFloat(x0), S15_16ToFloat(y0), c0);
```

`LinePath.java:3-26` carries a Sun 2006 GPLv2 header and `LineStroker.java:3-26` an Oracle 2007 header, so both are JDK-derived (per headers). A Java2D-style stroker is therefore reimplemented to run on the CPU and feed a triangle pipeline.

---

### 13. 2D versus 3D: strokes share the poly buffer
**File:** `core/src/processing/opengl/PGraphics2D.java:45` and `core/src/processing/opengl/PGraphicsOpenGL.java:2287`

```java
// PGraphics2D
public boolean is2D() { return true; }
public boolean is3D() { return false; }
protected void defaultPerspective() {
  super.ortho(0, width, -height, 0, -1, +1);   // :118-119
}

// PGraphicsOpenGL.flush()
if (is3D()) {
  if (hasLines) {
    flushLines();
    ...
  if (hasPoints) {
    flushPoints();
```

**What happens**: P2D differs from P3D by a flag and a default orthographic projection. `ortho/perspective/frustum` are replaced with warnings (:77-114). In 3D, strokes are screen-space-expanded line geometry drawn with a separate line shader (`flushLines`), and points likewise. In 2D, `flushLines` and `flushPoints` are not called at all, because `tessellateEdges2D` wrote the stroke triangles into the poly arrays. A P2D sketch therefore uses one shader and one index list for fills and strokes, with painter's ordering by emission order. `hint(DISABLE_OPTIMIZED_STROKE)` is refused in 2D (`PGraphicsOpenGL.java:1835-1840`: "Optimized strokes can only be disabled in 3D"), because it would force `FLUSH_CONTINUOUSLY`.

---

### 14. To the GPU
**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:2247` and `:2332`

```java
if (flushMode == FLUSH_WHEN_FULL) {
  // The modelview transformation has been applied already to the
  // tessellated vertices, so we set the OpenGL modelview matrix as
  // the identity to avoid applying the model transformations twice.
  modelview0 = modelview;
  modelviewInv0 = modelviewInv;
  modelview = modelviewInv = identity;
  projmodelview.set(projection);
}
if (hasPolys && !isDepthSortingEnabled) {
  flushPolys();
...
// flushPolys()
updatePolyBuffers(lights, texCache.hasTextures, needNormals, needTexCoords);
...
  PShaderOpenGL shader = getPolyShader(lights, tex != null);
  shader.bind();
  ...
      shader.draw(bufPolyIndex.glId, icount, ioffset);   // :2394
```

**What happens**: `flush()` swaps in an identity modelview (lines 2267-2278) because the CPU already transformed the vertices. `flushPolys` uploads the buffers (`updatePolyBuffers`), binds the poly shader, and loops over `IndexCache` ranges (one per texture or index-block break), issuing one draw per range. After the loop, `tessGeo.clear()` resets the batch (:2321).

The draw chain is three thin hops (`core/src/processing/opengl/PShaderOpenGL.java:585-590`, `core/src/processing/opengl/PGL.java:3243-3248`, `core/src/processing/opengl/PJOGL.java:1329-1330`):

```java
protected void draw(int idxId, int count, int offset) {
  pgl.bindBuffer(PGL.ELEMENT_ARRAY_BUFFER, idxId);
  pgl.drawElements(PGL.TRIANGLES, count, PGL.INDEX_TYPE,
                   offset * PGL.SIZEOF_INDEX);
  pgl.bindBuffer(PGL.ELEMENT_ARRAY_BUFFER, 0);
}
// PGL
public void drawElements(int mode, int count, int type, int offset) {
  geomCount += count;
  drawElementsImpl(mode, count, type, offset);
}
// PJOGL
public void drawElementsImpl(int mode, int count, int type, int offset) {
  gl.glDrawElements(mode, count, type, offset);
}
```

The abstract `PGL` isolates the backend (JOGL here). The mode is always `TRIANGLES`.

**Antialiasing** is MSAA only. `PGL.smoothToSamples` (`PGL.java:468-477`) maps `smooth(1)` to 2x, `smooth(0)` to 1x, and any other N to N samples. `PSurfaceJOGL.java:248-249` requests it from the window system:

```java
caps.setSampleBuffers(true);
caps.setNumSamples(PGL.smoothToSamples(graphics.smooth));
```

The offscreen multisample framebuffer is built in `PGL.java:952-998` (`renderbufferStorageMultisample(RENDERBUFFER, numSamples, RGBA8, ...)`). No shader-level coverage AA exists, so the polygon edges and the CPU-built stroke outline are both antialiased only by sample count.

---

### 15. Retained contrast: `PShape` tessellates once
**File:** `core/src/processing/core/PGraphics.java:4081` and `core/src/processing/opengl/PShapeOpenGL.java:5265`

```java
public void shape(PShape shape) {
  if (shape.isVisible()) {
    // Flushing any remaining geometry generated in the immediate mode
    // to avoid depth-sorting issues.
    flush();
    ...
    shape.draw(this);
// PShapeOpenGL.draw
    pre(gl);
    updateTessellation();
    updateGeometry();
// updateTessellation, :3532
    if (!root.tessellated) {
      root.tessellate();
      root.aggregate();
      root.initModified();
      root.needBufferInit = true;
    }
```

**What happens**: `shape()` flushes pending immediate geometry first, then `draw` calls `updateTessellation`. That runs `tessellate` only if `!root.tessellated` (`markForTessellation`, :3542-3545, clears the flag). `tessellate` (:3601-3631) allocates a `RETAINED` `TessGeometry` on the root (:3610) and calls `tessellateImpl` (:3659), which reuses the same `Tessellator` with `setTransform(matrix)` (:3697), i.e. the shape's own matrix instead of the frame's modelview. `initBuffers` (:4614-4632) uploads VBOs once. Later frames only run `render` (:5437-5467), whose `renderPolys` ends in `shader.draw(root.bufPolyIndex.glId, ...)` (:5553), the same shader entry as step 14 but reading persistent buffers.

Transforms on a retained shape apply to the matrix, not through re-tessellation (e.g. `resetMatrix`, :1358-1362). Pixel snapping (`clamp2D()`, `PGraphicsOpenGL.java:12261-12263`) is IMMEDIATE-only and requires no rotation or skew:

```java
boolean clamp2D() {
  return is2D && tess.renderMode == IMMEDIATE &&
         zero(pg.modelview.m01) && zero(pg.modelview.m10);
}
```

---

## Data Flow Diagram

```
User code: size(400,400[,P2D]); beginShape(); vertex(); bezierVertex(); endShape(CLOSE)
    |
    v
PApplet.size(): renderer = "processing.awt.PGraphicsJava2D" | "processing.opengl.PGraphics2D"
    |  makeGraphics(): loadClass().getConstructor().newInstance()  -> PGraphics g
    v
PGraphics front end (modes normalised: ellipseMode, rectMode -> *Impl)
    |
    +------------------------------+--------------------------------------------+
    |  JAVA2D                      |  P2D                                       |
    v                              v                                            |
beginShape: gpath = null     beginShape: inGeo.clear()                          |
    |                              |                                            |
vertex: moveTo / lineTo      vertex / bezierVertex: append to inGeo             |
bezierVertex: curveTo        (float[] positions + codes[])                      |
  (cubic kept as-is)               |                                            |
    |                        endShape -> tessellate(mode)                       |
endShape: closePath;               |                                            |
  append(auxPath)            POLYGON -> tessellatePolygon(solid=true)           |
    |                              |                                            |
    v                              +--> curves flattened (bezierDetail)         |
drawShape(gpath)                   +--> GLU gluTess (NONZERO) -> fan/strip/tris |
  g2.fill(gpath)                   |      -> TessellatorCallback -> indices     |
  g2.draw(gpath)                   +--> stroke: tessellateEdges2D               |
    |  BasicStroke(weight,cap,join)       fast: quads (addLineSegment2D)        |
    |  RenderingHints AA                  full: LinePath.createStrokedPath      |
    v                                      -> outline -> GLU -> triangles       |
JDK scanline rasterizer                    |                                    |
  (analytic coverage AA)             tessGeo: polyVertices(x,y,z,w), colors,    |
    |                                  indices, IndexCache ranges               |
    |                                  |                                        |
    |                            flush() when FLUSH_WHEN_FULL buffer is full,   |
    |                              or at frame end / forced flush               |
    |                                  |  identity modelview, ortho projection  |
    |                            flushPolys -> updatePolyBuffers, bind shader    |
    |                              -> shader.draw -> glDrawElements(TRIANGLES)  |
    |                                  |                                        |
    |                            MSAA framebuffer resolve                       |
    v                                  v                                        |
BufferedImage -> window            GL framebuffer -> window                     |
```

## Key Observations

1. **One API, two rasterizers.** Java2D keeps geometry as a path and lets the JDK own flattening, stroking and AA. P2D builds exact triangles on the CPU and leaves only MSAA to the GPU. The same sketch can differ in stroke joins, AA quality and the cost of curves.

2. **Fill path is chosen by shape kind, not convexity.** Fans, strips, triangles and quads use trivial index generation. Only `POLYGON` goes through GLU, even when the polygon is convex. No convexity test is done.

3. **Strokes are CPU triangles in both modes.** The fast mode emits one quad per segment with no caps or joins. The accurate mode strokes the path with a JDK-derived stroker (`LinePath`/`LineStroker`) and tessellates the outline with GLU. The immediate-mode threshold is stroke weight < 2 px after scale, or 5000 or more vertices. Retained shapes always take the accurate path. In 2D the strokes share the fill's buffer and shader, which is why `flushLines` is not needed (`flush()` calls it only when `is3D()`).

4. **Immediate mode re-tessellates on every `endShape`; retained tessellates once.** An animated sketch redoes GLU and stroking each frame. `PShape` pays once and then transforms by matrix. `shape()` forces a flush of the immediate batch first.

5. **Batching is partial.** `FLUSH_WHEN_FULL` accumulates many `endShape` calls into one buffer, and vertices are pre-transformed on the CPU, which is why `flush()` swaps in an identity modelview. Draw calls are split by `IndexCache` range (textures, index blocks), not by draw state, and there is no instancing.

6. **Curve flattening is not adaptive for Béziers.** Ellipses scale their vertex count with on-screen size, while Béziers use a fixed `bezierDetail` regardless of size or zoom. Flattened points are stored as `double[]` tuples in the GLU path.

7. **The whole pipeline is OpenGL 2-era.** There are no compute shaders, no instancing, no storage buffers, and no GPU-side stroking or curve evaluation. Everything between user vertices and the vertex buffer is CPU work, and AA is whatever the multisample count gives.

8. **Renderer selection by string and reflection.** It makes third-party renderers possible (any `PGraphics` subclass name works) at the cost of compile-time checking, and it forces a no-arg constructor plus a `setParent/setPrimary` two-phase init.

9. **The ODD winding rule is unreachable from immediate mode.** `tessellate` passes `solid = true` at `:2221`; only retained `PShapeOpenGL` (`:3738`) can select ODD. `noCapsJoins()` applies only in IMMEDIATE mode, and `clamp2D()` additionally requires no rotation or skew.

## Implications for Rust Framework (Flux)

### Adopt
- **Template-method front end.** Normalise modes once in a shared layer (`ellipse_mode`, `rect_mode`, negative extents) and hand canonical shapes to the backend. This keeps backend code small and semantics identical across targets.
- **Batching immediate-mode geometry.** Accumulate tessellated geometry across calls and flush on a full buffer or an explicit sync point. Keep an `IndexCache`-style range list so state changes (texture, shader) split draws only when needed.
- **Pre-transformed 2D vertices plus an ortho projection.** This avoids per-draw uniform churn and lets many shapes share one draw.
- **Screen-size-adaptive flattening** (as in `addEllipse`) for all curves, instead of a fixed detail count.
- **Separate retained and immediate geometry paths** with a transform-by-matrix retained shape, tessellating only when marked dirty.

### Modify
- **Fill tessellation.** Do not call a GLU-style tessellator for every polygon. Choose by classification: fan for convex, an ear-clipper or sweep-line tessellator (e.g. a lyon-style crate) for general paths, with an explicit fill-rule parameter (non-zero or even-odd) instead of Processing's `solid` flag. Or skip triangulation entirely; see the [rasterization strategies theme](../../../themes/vector-graphics/rasterization-strategies.md).
- **Strokes.** Keep CPU stroke expansion on desktop, mobile and web. But always produce caps and joins through one code path, instead of Processing's two, and make thickness limits explicit rather than hidden thresholds (2 px and 5000 vertices).
- **Antialiasing.** Prefer wgpu MSAA with an explicit sample-count setting on every target, falling back to an edge-feather option for the web, where MSAA availability is more restricted.
- **Renderer selection.** Use a trait object or an enum chosen at startup instead of loading classes by name.
- **Vertex layout.** Use a compact `#[repr(C)]` vertex (`[f32; 2]` position, `[u8; 4]` colour) instead of Processing's 25-element `double[]` per tessellator vertex.

### Avoid
- Per-vertex heap allocation in tessellation (the `Arrays.copyOf(vertexT, ...)` pattern in `addBezierVertex`). Reuse a scratch buffer.
- Hidden mode switches that change visual output (the stroke fast path switching on weight and vertex count, or `clamp2D` pixel snapping only in immediate mode).
- Re-tessellating unchanged shapes every frame. Offer a retained handle for anything that is drawn repeatedly.
- Designing around state that the GPU backend cannot see, like the swapped identity modelview. Pass the transform explicitly per batch.
- Running two different stroke implementations for 2D and 3D unless the 3D path (screen-space expansion in a shader) actually pays for itself. wgpu can do instanced line segments, which Processing could not.

### API Sketch

```rust
// One front end, backend-agnostic geometry sink.
pub trait ShapeSink {
    fn begin(&mut self, kind: ShapeKind);
    fn vertex(&mut self, p: Vec2);
    fn bezier(&mut self, c1: Vec2, c2: Vec2, p: Vec2);   // kept as a curve
    fn end(&mut self, close: bool, style: &DrawStyle);   // fill rule, stroke, transform
}

pub struct DrawStyle {
    pub fill: Option<Color>,
    pub stroke: Option<Stroke>,       // weight, cap, join, miter limit
    pub fill_rule: FillRule,          // NonZero | EvenOdd
    pub transform: Mat3,
}

// Immediate: flatten + tessellate on end(), append to a batch, flush when full or at sync points.
pub struct ImmediateBatch { vertices: Vec<Vertex>, indices: Vec<u32>, ranges: Vec<DrawRange> }

// Retained: tessellate lazily when dirty, upload once, apply the transform per draw.
pub struct RetainedShape { path: Path, mesh: Option<GpuMesh>, dirty: bool }

impl RetainedShape {
    pub fn draw(&mut self, ctx: &mut Frame, transform: Mat3) {
        if self.dirty { self.mesh = Some(ctx.tessellate_and_upload(&self.path)); self.dirty = false; }
        ctx.draw_mesh(self.mesh.as_ref().unwrap(), transform);
    }
}
```

## Related Documents

- [Rendering Pipeline](../rendering-pipeline.md) — the narrative version of this trace
- [Processing README](../README.md) — framework overview and entry points
- [Vector graphics theme](../../../themes/vector-graphics/README.md) — Processing's PShape data model
- [Rasterization strategies](../../../themes/vector-graphics/rasterization-strategies.md) — how CPU tessellation plus MSAA compares with stencil-fringe and coverage rendering

---

*This document is part of the [Processing study](../README.md).*
