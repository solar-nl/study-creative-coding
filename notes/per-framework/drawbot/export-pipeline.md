# Export Pipeline

How DrawBot routes drawing commands to different output formats.

> **Key Insight:** PDF serves as the canonical intermediate format. Raster and animation contexts first render to PDF via Quartz, then convert to the target format using `PDFDocument.pageAtIndex()` and `NSBitmapImageRep`.

## Format Routing

The `getContextForFileExt()` function in `context/__init__.py` maps file extensions to context classes:

```python
def getContextForFileExt(ext):
    for context in allContexts:
        if ext in context.fileExtensions:
            return context()
    return None
```

Each context declares its supported extensions via `fileExtensions = ["pdf"]`. The routing is simple extension matching against a priority-ordered list.

## PDF Pipeline (Direct Rendering)

`PDFContext` renders directly to a Quartz `CGContext`:

```python
def _newPage(self, width, height):
    mediaBox = Quartz.CGRectMake(0, 0, self.width, self.height)
    self._pdfData = Quartz.CFDataCreateMutable(None, 0)
    dataConsumer = Quartz.CGDataConsumerCreateWithCFData(self._pdfData)
    self._pdfContext = Quartz.CGPDFContextCreate(dataConsumer, mediaBox, None)
    Quartz.CGContextBeginPage(self._pdfContext, mediaBox)

def _saveImage(self, path, options):
    self._closeContext()
    self._writeDataToFile(self._pdfData, path, options)
```

All drawing commands (`_drawPath`, `_textBox`, `_image`) operate on `self._pdfContext` using Quartz calls like `CGContextFillPath`, `CGContextDrawImage`, and `CTRunDraw`.

## Raster Pipeline (PDF to Bitmap)

`ImageContext` extends `PDFContext` and converts each PDF page to a bitmap:

```python
def _writeDataToFile(self, data, path, options):
    pdfDocument = Quartz.PDFDocument.alloc().initWithData_(data)
    for index in range(firstPage, pageCount):
        page = pdfDocument.pageAtIndex_(index)
        imageRep = _makeBitmapImageRep(pdfPage=page, imageResolution=72.0)
        imageData = imageRep.representationUsingType_properties_(
            self._saveImageFileTypes[ext], properties
        )
        imageData.writeToFile_atomically_(imagePath, True)
```

The `_makeBitmapImageRep` function creates an `NSBitmapImageRep` at the target resolution and draws the PDF page into it using `CGContextDrawPDFPage`.

## Animation Pipeline

### GIF: Pages to Frames via [gifsicle](https://www.lcdf.org/gifsicle/)

`GIFContext` renders all pages as temporary GIFs, then assembles them:

```python
def _writeDataToFile(self, data, path, options):
    if shouldBeAnimated:
        options["multipage"] = True
        tempPath = tempfile.mkstemp(suffix=".gif")[1]
    super()._writeDataToFile(data, tempPath, options)
    if shouldBeAnimated:
        generateGif(self._inputPaths, path, self._delayData, loop=True)
```

The `generateGif` function invokes [gifsicle](https://www.lcdf.org/gifsicle/) with frame delays:

```python
cmds = [gifsiclePath, "-w", "--colors", "256", "--loop"]
for i, inputPath in enumerate(sourcePaths):
    cmds += ["--delay", "%i" % delays[i], inputPath]
cmds += ["--output", destPath]
```

### MP4: Pages to Frames via [ffmpeg](https://ffmpeg.org/)

`MP4Context` extends `PNGContext` and exports frames to a temp directory:

```python
def _writeDataToFile(self, data, path, options):
    tempDir = tempfile.mkdtemp(suffix=".mp4tmp")
    super()._writeDataToFile(data, os.path.join(tempDir, "frame.png"), options)
    generateMP4(os.path.join(tempDir, "frame_%d.png"), path, frameRate, codec)
    shutil.rmtree(tempDir)
```

The `generateMP4` function runs [ffmpeg](https://ffmpeg.org/) with H.264 encoding:

```python
cmds = [ffmpegPath, "-y", "-r", str(frameRate), "-i", imageTemplate,
        "-c:v", codec, "-crf", "20", "-pix_fmt", "yuv420p", mp4path]
```

## SVG Pipeline (Direct XML Generation)

`SVGContext` bypasses Quartz entirely, generating SVG XML via `fontTools.misc.xmlWriter`:

```python
def _newPage(self, width, height):
    self._svgData = self._svgFileClass()
    self._svgContext = XMLWriter(self._svgData, encoding="utf-8")
    self._svgContext.begintag("svg", [("width", self.width), ("height", self.height)])
```

Drawing commands translate to SVG elements: `<path>` for shapes, `<text>/<tspan>` for text, `<image>` with base64-encoded data for images.

## Export Capabilities

| Format | Context | Dependencies | Multi-page | Animation |
|--------|---------|--------------|------------|-----------|
| PDF | PDFContext | Quartz | Yes | No |
| SVG | SVGContext | None (pure XML) | Via multipage | No |
| PNG | PNGContext | Quartz | Via multipage | No |
| JPEG | JPEGContext | Quartz | Via multipage | No |
| TIFF | TIFFContext | Quartz | Via multipage | No |
| BMP | BMPContext | Quartz | Via multipage | No |
| GIF | GIFContext | [gifsicle](https://www.lcdf.org/gifsicle/) | Yes | Yes |
| MP4 | MP4Context | [ffmpeg](https://ffmpeg.org/) | N/A | Yes |

## Recommendations for Your Framework

1. **Embrace PDF as Intermediate Format** - Quartz's PDF rendering is high-quality and handles text/vector perfectly. For cross-platform, [wgpu](https://github.com/gfx-rs/wgpu) could render to an internal texture, then export via image encoders.

2. **Context Trait with Extension Matching** - The `fileExtensions` pattern maps cleanly to Rust:
   ```rust
   trait ExportContext {
       fn extensions(&self) -> &[&str];
       fn save(&self, document: &Document, path: &Path) -> Result<()>;
   }
   ```

3. **External Tool Integration** - DrawBot shells out to [gifsicle](https://www.lcdf.org/gifsicle/)/[ffmpeg](https://ffmpeg.org/) for animation. Consider using Rust crates (`gif`, `mp4`) for zero-dependency builds, with optional [ffmpeg](https://ffmpeg.org/) for advanced codecs.

4. **Resolution-Independent Rendering** - The PDF-first approach means all content is resolution-independent until rasterization. Match this by keeping your scene graph in logical coordinates.

5. **Multipage Option Pattern** - The `multipage` option for batch export is user-friendly. Implement as an enum: `ExportMode::LastPage | ExportMode::AllPages | ExportMode::Range(start, end)`.
