# Framework Support Matrix: Who Reads and Writes Which Format

> Which of the studied frameworks can load or save each open asset format, and through what mechanism?

Part of the [open formats research](./README.md). Scope and criteria are in the [research brief](../open-formats-research-brief.md).

## Key Insight

> **The surprise is USD.** Two of the five web projects read OpenUSD today, and they took opposite routes: three.js wrote a pure-JavaScript `.usda`/`.usdc` parser with a composition engine that resolves references, payloads and variants, while Babylon.js compiled Pixar's C++ runtime to WebAssembly and flattens the result into its own materials. No native or Rust project in this tree has a verifiable USD reader (openFrameworks and vvvv bundle Assimp and Stride importers whose format lists live outside the tree). Beyond that, the mechanism splits by host: the browser engines write their own parsers for everything that is not a codec (OBJ, SVG, EXR, HDR), the native engines borrow stb_image and tinyexr for the same formats, everyone takes Draco and Basis as WebAssembly or C++, and raster images go to the platform wherever there is one.

---

## Why Survey This

Before Flux commits to a format list, the question is which of these formats a studied tool has already proven it can load, and at what dependency cost. The landscape document says what each format *is*. This one says what the frameworks under study actually *do* with it. A format with a beautiful specification and no loader in any creative-coding tool is a format Flux would have to implement alone. A format every tool reads through the same third-party library tells Flux which dependency the ecosystem has already accepted.

So each row below is a claim about source code, cited as `path:line` so it can be re-checked. The commits read are listed at the end and recorded in the 2026-10-25 snapshot of [`notes/SUBMODULE-PINS.md`](../../notes/SUBMODULE-PINS.md). Line numbers drift, so to reproduce a citation at the surveyed commit use `git -C <submodule> show <commit>:<path>`.

---

## Who Reads What

Legend: **I** import, **E** export, **I/E** both, blank means not supported, (t) means only in an offline tool, (x) means only through an addon or an example rather than the core API, (f) means flattened on load.

| Format | three.js | Babylon.js | PixiJS | cables | p5.js v1 | Filament | oF | Cinder | Processing | openrndr + orx | nannou | tixl | VL.StandardLibs | vello | rend3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **OpenUSD** (.usda/.usdc/.usdz) | I/E (E is usdz) | I(f) wasm, E usdz | | | | | (x) Assimp | | | | | | (x) Stride/Assimp | | |
| **glTF 2.0** | I/E | I/E | | I (glb) | | I | I (Assimp) | | | I (dnk3) | | I | I (Stride) | | I |
| **OBJ/MTL** | I/E | I/E | | I/E | I/E | I(t) | I (Assimp) | I/E | I | I/E | | I/E | I (Stride) | | (x) |
| **PLY** | I/E | I (splat only) | | I | | | I/E | | | | | | | | |
| **STL** | I/E | I/E | | | I/E | | I (Assimp) | | | | | | | | |
| **3MF** | I | E | | | | | | | | | | | | | |
| **Draco** | I/E wasm | I wasm | | I wasm | | I (flag) | | | | | | | | | |
| **MaterialX** | I | | | | | | | | | | | | | | |
| **OpenPBR** | I (via USD, MaterialX) | native material, E as `KHR_materials_openpbr` | | | | | | | | | | | | | |
| **OpenEXR** | I/E | I | | I/E | | I/E | I/E | I/E | | I/E | I (opt-in) | | | | |
| **Radiance HDR** | I | I | | | | I/E | I/E | I/E | | I/E | I (opt-in) | | | | |
| **PNG** | I (browser) | I/E (browser, canvas) | I/E | I/E | I/E | I/E | I/E | I/E | I/E | I/E | I/E | I/E | I/E | I/E | I |
| **KTX2 / Basis** | I wasm, E (raw only) | I wasm | I wasm | I wasm | | I/E | | KTX1 only | | | I (opt-in) | | | | I (raw only) |
| **DDS** | I | I | I | | | E | I/E (FreeImage) | I | | I | I (opt-in) | I | I/E (Stride) | | I |
| **WebP / AVIF** | I (browser) | I/E (browser) | I (browser) | I (browser) | I (browser) | I WebP | I (FreeImage) | | | | I WebP only (opt-in) | | | | |
| **SVG** | I/E | | I/E | I (raster + path) | | | I/E (addon), E Cairo | I, E Cairo | I, E Batik | I/E | (x) usvg | I | I/E Skia | (x) usvg | |
| **PDF** | | | | | | | E Cairo | E Cairo | E iText | | | | E Skia | | |
| **Lottie** | | | | I (lottie-web) | | | | | | | | | I (Skottie) | | |
| **FBX** (closed) | I | I | | | | I(t) Assimp | I (Assimp) | | | | | | I (Stride) | | |

DrawBot, apEx and werkkzeug4 are omitted from the grid because they are export-only or self-contained. Their rows are in the per-project sections.

---

## Browser Engines Write Parsers, Native Engines Borrow stb and tinyexr

Read the mechanism column across every project and a pattern falls out. Nobody writes a Draco decoder or a Basis transcoder; those arrive as WebAssembly in the browser projects and as the Google C++ libraries in Filament. Nobody writes a PNG decoder in a browser project; the platform does it. For the formats in between, the host decides: three.js, Babylon and cables (by vendoring three.js) carry their own OBJ, PLY, EXR and HDR readers because a browser has nothing else to offer, while Filament, Cinder and openrndr take stb_image and tinyexr, openFrameworks takes FreeImage, and nannou takes the `image` crate. OBJ is the one format nearly everyone parses by hand, native or not.

```
                 own parser                third-party codec              platform
                 ──────────                ─────────────────              ────────
 three.js        OBJ PLY STL EXR HDR       Draco(wasm) Basis(wasm)        PNG JPEG WebP AVIF
                 SVG USD MaterialX 3MF     UTIF (TIFF) fflate (zip)
 Babylon.js      OBJ STL EXR HDR FBX       OpenUSD(wasm) Draco(wasm)      PNG JPEG WebP AVIF
                 USDZ(write)               MSC/UASTC transcoders(wasm)
 Filament        HDR PSD                   cgltf draco meshopt basisu     (none: native)
                                           stb_image libpng tinyexr libwebp
 openrndr+orx    DDS SVG OBJ glTF(dnk3)    stb_image tinyexr (LWJGL)      (none: JVM)
 nannou          (none)                    Bevy asset loaders, image crate (none)
 tixl            OBJ                       SharpGLTF, Svg.NET, JeremyAnsel.Dds   WIC (PNG JPEG BMP TIFF)
```

The split matters for Flux because it predicts cost. Everything the browser engines parse by hand is small enough that Rust has a pure crate for it (`tobj`, `exr`, `image`), so that column costs Flux nothing but a dependency line. The codec column is where C++ enters on every platform, and the Rust crate map in [`rust-crates.md`](./rust-crates.md) checks each entry for a pure-Rust alternative.

---

## What Each Project Does, With Citations

### three.js

The broadest surface in the repo: eight exporters (glTF, USDZ, OBJ, PLY, STL, Draco, EXR, KTX2) and more than forty loaders. Three findings stand out.

**USD without C++.** `USDLoader` ([USDLoader.js:27](../../libraries/web/threejs/examples/jsm/loaders/USDLoader.js)) dispatches to a hand-written `USDAParser` for text layers and a `USDCParser` ([USDCParser.js:505](../../libraries/web/threejs/examples/jsm/loaders/usd/USDCParser.js)) for the binary crate format. On top sits `USDComposer` ([USDComposer.js:82](../../libraries/web/threejs/examples/jsm/loaders/usd/USDComposer.js)), which resolves references, payloads and variant selections before building a three.js scene. Material binding handles both `UsdPreviewSurface` and the OpenPBR surface ([USDComposer.js:3029-3035](../../libraries/web/threejs/examples/jsm/loaders/usd/USDComposer.js)). USDZ archives are unzipped with fflate. The exporter goes the other way: `USDZExporter` ([USDZExporter.js:138](../../libraries/web/threejs/examples/jsm/exporters/USDZExporter.js)) writes `#usda 1.0` text, one geometry layer per mesh referenced from a root layer, `UsdPreviewSurface` materials, and zips at level 0 as the usdz spec requires.

**MaterialX, including OpenPBR.** `MaterialXLoader` ([MaterialXLoader.js:33](../../libraries/web/threejs/examples/jsm/loaders/MaterialXLoader.js)) parses `.mtlx` and compiles node graphs to TSL (the WebGPU node material language). The surface mappings cover `standard_surface`, `gltf_pbr`, `UsdPreviewSurface` and `open_pbr_surface` ([MaterialXSurfaceMappings.js:369](../../libraries/web/threejs/examples/jsm/loaders/materialx/MaterialXSurfaceMappings.js), `applyOpenPbrSurface`).

**glTF extension coverage.** The loader's extension table ([GLTFLoader.js:130](../../libraries/web/threejs/examples/jsm/loaders/GLTFLoader.js) onwards) implements Draco, lights_punctual, clearcoat, diffuse_roughness, dispersion, ior, sheen, specular, transmission, iridescence, anisotropy, unlit, volume, emissive_strength, texture_basisu, texture_transform, mesh_quantization, EXT_materials_bump, EXT_texture_webp, EXT_texture_avif, EXT_meshopt_compression and EXT_mesh_gpu_instancing. `KHR_materials_variants` is an external plugin. The exporter ([GLTFExporter.js:104](../../libraries/web/threejs/examples/jsm/exporters/GLTFExporter.js)) writes the same materials set minus diffuse_roughness.

| Format | Direction | Mechanism | Citation |
|---|---|---|---|
| OBJ / MTL | I / E (OBJ) | own | `loaders/OBJLoader.js:457`, `loaders/MTLLoader.js:34`, `exporters/OBJExporter.js:22` |
| PLY | I / E | own, plus a Gaussian-splat PLY loader | `loaders/PLYLoader.js:35`, `exporters/PLYExporter.js:24`, `loaders/GaussianSplatPLYLoader.js:65` |
| STL | I / E | own | `loaders/STLLoader.js:54`, `exporters/STLExporter.js:18` |
| 3MF | I | own XML parser plus fflate | `loaders/3MFLoader.js:26,62` |
| Draco | I / E | Google decoder as WASM in a worker; encoder as a global script | `loaders/DRACOLoader.js:17,56`, `exporters/DRACOExporter.js:3,31` |
| KTX2 / Basis | I / E | Basis transcoder WASM plus zstddec; exporter writes uncompressed VK formats via `ktx-parse`, no Basis encoding | `loaders/KTX2Loader.js:103,106,142`, `exporters/KTX2Exporter.js:21,140` |
| KTX1, DDS, PVR | I | own `CompressedTextureLoader` subclasses | `loaders/KTXLoader.js:22`, `DDSLoader.js:25`, `PVRLoader.js:22` |
| OpenEXR | I / E | own; fflate for zlib | `loaders/EXRLoader.js:12,97`, `exporters/EXRExporter.js:45` |
| Radiance HDR | I | own (`RGBELoader` is an alias of `HDRLoader`) | `loaders/HDRLoader.js:24`, `RGBELoader.js:5` |
| Ultra HDR (JPEG gain map) | I | own | `loaders/UltraHDRLoader.js:71` |
| TIFF | I | bundled UTIF | `loaders/TIFFLoader.js:7,21` |
| PNG / JPEG / WebP / AVIF | I | browser (`<img>`, `createImageBitmap`) | `src/loaders/ImageLoader.js:20,88`, `src/loaders/ImageBitmapLoader.js:35,179` |
| SVG | I / E | own path and style parser to `ShapePath`; `SVGRenderer` emits SVG DOM | `loaders/SVGLoader.js:66,298`, `renderers/SVGRenderer.js:77` |
| Collada, FBX (closed), LWO, MD2, 3DS | I | own | `ColladaLoader.js:32`, `FBXLoader.js:47,78`, `LWOLoader.js:55`, `MD2Loader.js:110`, `TDSLoader.js:31` |
| Open long tail: VRML, AMF, PCD, XYZ, VTK, NRRD, IES, LDraw, SPZ, 3DM (rhino3dm WASM) | I | own unless noted | `VRMLLoader.js:54`, `AMFLoader.js:29`, `PCDLoader.js:35`, `XYZLoader.js:31`, `VTKLoader.js:32`, `NRRDLoader.js:21`, `IESLoader.js:31`, `LDrawLoader.js:1773`, `SPZLoader.js:66`, `3DMLoader.js:57` |

All paths are under `libraries/web/threejs/examples/jsm/` unless they start with `src/`.

### Babylon.js

Babylon is the one project with a **native OpenPBR material**. `OpenPBRMaterial` ([openpbrMaterial.pure.ts:515](../../libraries/web/babylonjs/packages/dev/core/src/Materials/PBR/openpbrMaterial.pure.ts)) exposes the spec's lobe names directly: `base_weight`, `specular_*`, `coat_*`, `fuzz_*`, `thin_film_*`, `subsurface_*`. The glTF loader switches to it when `useOpenPBR` is set or when a material carries `KHR_materials_openpbr` (`glTFLoader.pure.ts:466,2375`), and the serializer writes that extension ([KHR_materials_openpbr.pure.ts:7,14](../../libraries/web/babylonjs/packages/dev/serializers/src/glTF/2.0/Extensions/KHR_materials_openpbr.pure.ts)), marked `@experimental` because the Khronos spec is still a draft. Babylon also implements the newer `KHR_materials_coat`, `_fuzz`, `_diffuse_roughness` and `_volume_scatter`, which are the glTF-side counterparts of OpenPBR lobes.

**USD through WebAssembly.** `USDFileLoader` ([usdFileLoader.pure.ts:98,103-106](../../libraries/web/babylonjs/packages/dev/loaders/src/USD/usdFileLoader.pure.ts)) fetches `babylon-usd-importer.wasm`, a `.data` bundle and a worker script from the Babylon CDN. The worker is OpenUSD itself; it streams a binary command buffer (`usdCommandProtocol.ts:116`) that `usdSceneMaterializer.ts:12` turns into meshes and `PBRMaterial` instances. The result is a flattened scene: composition happens inside the WASM runtime, and Babylon never sees layers. Export is a hand-written USDZ writer (`usdzExporter.ts:676`).

| Format | Direction | Mechanism | Citation (under `packages/dev/`) |
|---|---|---|---|
| glTF 2.0 / GLB | I | own; extension set: animation_pointer, draco, gaussian_splatting, interactivity, lights_punctual, materials_{anisotropy, clearcoat, coat, diffuse_roughness, diffuse_transmission, dispersion, emissive_strength, fuzz, ior, iridescence, pbrSpecularGlossiness, sheen, specular, transmission, unlit, variants, volume, volume_scatter}, mesh_quantization, node_{hoverability, selectability, visibility}, texture_basisu, texture_transform, xmp_json_ld; EXT_lights_{area, ies, image_based}, mesh_gpu_instancing, meshopt_compression, texture_avif, texture_webp; MSFT_{audio_emitter, lod, minecraftMesh, sRGBFactors} | `loaders/src/glTF/glTFFileLoader.pure.ts:466`, `loaders/src/glTF/2.0/glTFLoader.pure.ts:197`, `loaders/src/glTF/2.0/Extensions/` |
| glTF 2.0 / GLB | E | own serializer; writes EXT_lights_area, mesh_gpu_instancing, texture_avif, texture_webp, KHR_draco, interactivity, lights_punctual, the materials set above plus `openpbr`, texture_basisu, texture_transform | `serializers/src/glTF/2.0/glTFSerializer.ts:156` |
| OBJ / MTL | I / E | own | `loaders/src/OBJ/objFileLoader.pure.ts:29`, `serializers/src/OBJ/objSerializer.ts:12` |
| STL | I / E | own | `loaders/src/STL/stlFileLoader.pure.ts:16`, `serializers/src/stl/stlSerializer.ts:9` |
| 3MF | E only | own | `serializers/src/3MF/3mfSerializer.ts:90` |
| FBX (closed) | I | own ASCII and binary parsers with own inflate | `loaders/src/FBX/fbxFileLoader.pure.ts:178` |
| PLY (splat), .splat, .spz, .sog | I | own, splat-oriented (not a general PLY reader) | `loaders/src/SPLAT/splatFileLoader.pure.ts:41` |
| KTX2 / Basis | I | MSC transcoder, UASTC-to-ASTC/BC7/RGBA modules and a zstd decoder, all WASM in a worker | `core/src/Misc/khronosTextureContainer2.ts:203,214-222` |
| .basis, KTX1, DDS, TGA, IES, .env | I | own; `.basis` via the transcoder | `core/src/Materials/Textures/Loaders/textureLoaderManager.ts:46-61` |
| OpenEXR | I | own TS decoder (HUF, RLE, zip) | `core/src/Materials/Textures/Loaders/exrTextureLoader.ts:89` |
| Radiance HDR | I | own | `core/src/Materials/Textures/Loaders/hdrTextureLoader.ts:11` |
| PNG / JPEG / WebP / AVIF | I / E | browser decode; canvas encode for screenshots; MediaRecorder for WebM | `core/src/Misc/fileTools.pure.ts:205,230,309`, `core/src/Misc/screenshotTools.pure.ts:47` |
| Draco | I | WASM from the CDN | `core/src/Meshes/Compression/dracoDecoder.ts:42` |
| MaterialX | none | no `.mtlx` reader anywhere | |

### PixiJS

A 2D engine, so no scene formats. The interesting row is SVG, which has two modes. By default the browser rasterizes it into a texture ([loadSVG.ts:34,50](../../libraries/web/pixijs/src/assets/loader/parsers/textures/loadSVG.ts)). With `parseAsGraphicsContext` ([loadSVG.ts:77-82](../../libraries/web/pixijs/src/assets/loader/parsers/textures/loadSVG.ts)) PixiJS's own `SVGParser` (`src/scene/graphics/shared/svg/SVGParser.ts:37,48`) turns path, circle, rect, ellipse, line, polygon, polyline and group elements into vector `GraphicsContext` instructions. The parser leans on the DOM (strings go through `innerHTML`), so it would not port to a non-browser host as-is. The reverse exists too: `graphicsContextToSvg` (`SVGExporter.ts:21`) serializes Graphics instructions to an SVG string, skipping textures.

| Format | Direction | Mechanism | Citation (under `src/`) |
|---|---|---|---|
| PNG / JPEG / WebP / AVIF | I / E | browser `createImageBitmap` (also in a worker); `canvas.toDataURL` for export | `assets/loader/parsers/textures/loadTextures.ts:18,75,103`, `rendering/renderers/shared/extract/ExtractSystem.ts:15-19,431,594` |
| KTX2 | I | `libktx` WASM in a worker | `compressed-textures/ktx2/loadKTX2.ts:23`, `ktx2/worker/ktx.worker.ts:47` |
| .basis | I | Basis transcoder WASM | `compressed-textures/basis/loadBasis.ts:21` |
| KTX1, DDS | I | own | `compressed-textures/ktx/loadKTX.ts:21`, `dds/loadDDS.ts:21` |
| GIF (animated) | I | bundled `gifuct-js` | `gif/GifSource.ts:1,141` |
| Video | I | browser `<video>` | `assets/loader/parsers/textures/loadVideoTextures.ts:18,162` |

### cables

cables **flattens glTF into the patch**. The GLB parser, node, mesh, skin and morph-target classes all live inside the `GltfScene_v5` op (`src/ops/base/Ops.Gl.GLTF.GltfScene_v5/`). It reads KHR_lights_punctual, KHR_draco_mesh_compression, KHR_texture_basisu, KHR_texture_transform, EXT_texture_webp, EXT_mesh_gpu_instancing and KHR_materials_unlit (`att_inc_gltf.js:349,366,391-423`); `KHR_materials_variants` yields only the variant names; emissive_strength and ior are commented-out TODOs. glTF materials do not become cables materials: the user wires cables material ops to a `Materials` port and they are matched by glTF material name ([GltfScene_v5.js:488-530](../../visual-programming/cables/src/ops/base/Ops.Gl.GLTF.GltfScene_v5/Ops.Gl.GLTF.GltfScene_v5.js)); optionally the metallic-roughness factors and textures are pushed into that shader's uniforms (`att_inc_material.js:73,246`). Draco and KTX2 decoding ship as separate helper ops that carry the WASM (`Ops.Gl.GLTF.GltfDracoCompression_v2/`, `Ops.Gl.GLTF.KtxCompression_v2/`).

| Format | Direction | Mechanism | Citation (under `src/ops/`) |
|---|---|---|---|
| GLB | I | own (binary only; the port filter is `.glb`); also a three.js-backed loader in the Three extension | `base/Ops.Gl.GLTF.GltfScene_v5/Ops.Gl.GLTF.GltfScene_v5.js:6`, `extensions/Ops.Extension.Three/Ops.Extension.Three.GltfLoader/...js:3,16` |
| OBJ | I / E | own minimal parser ("todo: support quads"); own writer | `base/Ops.Graphics.Geometry.ObjGeometry/...js:1-3,56`, `base/Ops.Graphics.Geometry.GeometryToObj/...js:3,31` |
| PLY | I | own | `extensions/Ops.Extension.Misc3dFormats/Ops.Extension.Misc3dFormats.PlyGeometry/...js:2` |
| OpenEXR | I / E | vendored three.js `EXRLoader` plus fflate; own writer | `base/Ops.Gl.Textures.ExrTexture/exrloader.js:72`, `base/Ops.Graphics.ArrayToExr/...js:2-7` |
| KTX2 / Basis | I | vendored three.js `KTX2Loader` plus Basis WASM | `base/Ops.Gl.KtxTexture/Ops.Gl.KtxTexture.js:2,18` |
| SVG | I | raster via a `data:image/svg+xml` image; vector via SVG path to earcut triangles | `base/Ops.Gl.Textures.TextureSVG_v2/...js:49,90`, `base/Ops.Graphics.Geometry.SvgPathToGeometry_v3/` |
| Lottie | I | bundled lottie-web 5.13.0 | `extensions/Ops.Extension.Lottie/Ops.Extension.Lottie.LottieTexturePlayer_v2/...js:207` |
| PNG / JPEG / WebP | I / E | browser; `cgl.screenShot`; MediaRecorder | `src/corelibs/cgl/cgl_texture.js:657,700`, `src/corelibs/cgl/cgl_state.js:362` |
| USD, FBX, STL, MaterialX, HDR | none | none among 1,796 base ops and 35 extension sets | |

### p5.js (v1 line)

The smallest surface. `loadModel` ([loading.js:344](../../frameworks/p5js/src/webgl/loading.js)) parses OBJ (following `mtllib` to a sibling `.mtl`, `:505,562`) and ASCII or binary STL (`:699,765,857`); `p5.Geometry.saveObj` and `saveStl` write them back (`webgl/p5.Geometry.js:977,1088`). Raster images go through the browser (`image/loading_displaying.js:108,154`), animated GIF through the bundled `omggif` and `gifenc` libraries, fonts through opentype.js. No glTF, no SVG (the p5.js-svg add-on is external), no HDR.

### Filament

The most complete **native** glTF importer. `AssetLoader` ([AssetLoader.cpp:56,403](../../libraries/cpp/filament/libs/gltfio/src/AssetLoader.cpp)) parses with cgltf and keeps the node hierarchy, variants and an animator. Material extension flags are mapped into the ubershader or JIT material key ([AssetLoader.cpp:1473-1512](../../libraries/cpp/filament/libs/gltfio/src/AssetLoader.cpp)): clearcoat, transmission, sheen, ior, volume, dispersion, specular, emissive_strength, pbrSpecularGlossiness and unlit. Iridescence and anisotropy are absent. Codecs are all third-party: Draco behind a build flag (`DracoCache.cpp:20,112-116`), meshopt for `EXT_meshopt_compression` (`ResourceLoader.cpp:302,447`), basisu through `Ktx2Reader` (`Ktx2Provider.cpp:17`), libwebp for `EXT_texture_webp`, stb_image for PNG and JPEG (`TextureProvider.h:171-187`). gltfio only imports.

The offline side writes what the runtime reads. `imageio` decodes PNG, HDR, PSD and EXR by signature sniffing ([ImageDecoder.cpp:28,42,138-146](../../libraries/cpp/filament/libs/imageio/src/ImageDecoder.cpp)) and encodes PNG, PNG-linear, RGBM, HDR, PSD, EXR (half, PIZ), DDS and RGB_10_11_11 (`ImageEncoder.h:31-45`). `mipgen` writes KTX1 and Basis-encoded KTX2 (`tools/mipgen/src/main.cpp:20,56-57`, `BasisEncoder.cpp:25`); `cmgen` writes KTX cubemaps (`cmgen.cpp:169`). `filamesh` converts OBJ, FBX and anything else Assimp reads into Filament's own `.filamesh` (`tools/filamesh/src/main.cpp:39,353`); Assimp is never used at runtime.

### openFrameworks

Images go through FreeImage in both directions: the `ofImageFormat` enum ([ofImage.h:41-76](../../frameworks/openframeworks/libs/openFrameworks/graphics/ofImage.h)) lists PNG, JPEG, TIFF, BMP, GIF, TGA, PSD, DDS, HDR, EXR, JPEG 2000, PFM and RAW, and `FreeImage_Save` handles export (`ofImage.cpp:250-276,502-524`). `ofMesh` has its own PLY reader and writer (`ofMesh.inl:1093,1140,1333-1337`). Vector export is Cairo: `ofCairoRenderer` creates PDF and SVG surfaces ([ofCairoRenderer.cpp:75-85,91](../../frameworks/openframeworks/libs/openFrameworks/graphics/ofCairoRenderer.cpp)). 3D import is Assimp through `ofxAssimp` and the legacy `ofxAssimpModelLoader` (`addons/ofxAssimp/src/Source/ofxAssimpSrcScene.cpp:61,90`), which covers glTF, FBX, OBJ, Collada and 3DS; no Assimp exporter is called. `ofxSvg` has its own DOM on pugixml with `load` and `save` (`addons/ofxSvg/src/ofxSvg.cpp:187,300`).

### Cinder

Cinder reads and writes images through a registry of sources and targets. stb_image handles JPG, PNG, BMP, PSD, TGA, GIF and HDR ([ImageSourceFileStbImage.cpp:45-52](../../frameworks/cinder/src/cinder/ImageSourceFileStbImage.cpp)), stb_image_write for PNG, BMP, TGA and HDR, libpng, an own Radiance reader, tinyexr for EXR in both directions (`ImageFileTinyExr.cpp:48,259`), an own QOI codec, and the platform (ImageIO on macOS, WIC on Windows) for whatever else the OS lists. `gl::Texture` uploads KTX1 and DDS (DXT1/3/5, BC7) directly (`include/cinder/gl/Texture.h:550-554`). `ObjLoader` is a `geom::Source` with a matching `writeObj` (`include/cinder/ObjLoader.h:48,73,160`); `TriMesh` has its own binary format. SVG import is an own `svg::Doc` on rapidxml (`include/cinder/svg/Svg.h:813-820`); SVG, PDF, PS and EPS export come from the Cairo block (`blocks/Cairo/include/cinder/cairo/Cairo.h:134-206`). No glTF, FBX or USD in core, and no Assimp block.

### Processing

`PShapeSVG` ([PShapeSVG.java:120-123](../../frameworks/processing/core/src/processing/core/PShapeSVG.java)) and `PShapeOBJ` (`PShapeOBJ.java:50-69`) are own parsers; OBJ's `kd`, `ka` and `ks` map to fill, ambient and specular. Images load through Java ImageIO plus an own TGA path (`awt/ShimAWT.java:461-492`, `PImage.java:2860`) and save through ImageIO and an own TGA writer (`PImage.java:3267-3283`). The export libraries are heavyweight: SVG via Apache Batik's `SVGGraphics2D` (`java/libraries/svg/src/processing/svg/PGraphicsSVG.java:27,37`, batik-all 1.19), PDF via iText 2.1.7 (`java/libraries/pdf/src/processing/pdf/PGraphicsPDF.java:51,140`), and an own DXF writer (`java/libraries/dxf/src/processing/dxf/RawDXF.java:115,280`).

### openrndr and orx

The whole raster surface is one enum: `ImageFileFormat` lists JPG, PNG, DDS, EXR and HDR ([ImageFileFormat.kt:6-11](../../frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/ImageFileFormat.kt)). The stb image driver loads PNG, JPG and HDR through LWJGL's stb_image and saves them through stb_image_write; EXR load and save go through LWJGL's tinyexr binding (`openrndr-imagedriver-stb/src/main/kotlin/ImageDriverStbImage.kt:13-17,434,689`). DDS has an own reader with DX10 header support (`openrndr-dds/src/commonMain/kotlin/DDSReader.kt:209`). No KTX2, no WebP.

orx adds the vector and scene formats. `orx-svg` parses with jsoup into the `Composition` tree and has its own writer (`orx-svg/src/jvmMain/kotlin/SVGLoader.kt:13-38`, `SVGWriter.kt:18,90`). `orx-obj-loader` reads and writes OBJ (`OBJLoader.kt:13-45`, `ObjWriter.kt:9`). `orx-dnk3` is a hand-written kotlinx.serialization glTF model, JVM-only, that handles skins, animations, `KHR_lights_punctual` and the obsolete `KHR_materials_pbrSpecularGlossiness` ([Gltf.kt:58,293,368,438](../../libraries/openrndr-ecosystem/orx/orx-jvm/orx-dnk3/src/main/kotlin/gltf/Gltf.kt)) and nothing else. `orx-g-code` generates plotter and CNC output (`orx-g-code/src/commonMain/kotlin/generator.kt:12-21`). No PDF writer was found.

### nannou

nannou forwards everything to Bevy. Its `Cargo.toml` enables PNG and JPEG by default ([nannou/Cargo.toml:53-58](../../frameworks/nannou/nannou/Cargo.toml)) and exposes BMP, DDS, EXR, HDR, KTX2, Basis, GIF, ICO, PNM, QOI, TGA, TIFF, WebP and Farbfeld as opt-in features (`:103-118`; no AVIF) that map one-to-one onto Bevy's asset-loader features. `nannou_wgpu` builds textures from the `image` crate (`nannou_wgpu/src/texture/image.rs:96`). Screenshots use Bevy's `Screenshot` with `save_to_disk` (`nannou/src/context.rs:44,622-623`). glTF is not enabled anywhere even though `bevy_gltf` exists, and SVG appears only in a generative-design example that uses usvg (`generative_design/image/p_4_3_1_02.rs:86-89`). This is the closest existing model of a Rust "feature-gated codecs" design.

### tixl

tixl can **keep a glTF scene as a hierarchy or flatten it**, which makes it the clearest precedent for the Flux USD question. `LoadGltfScene` loads with SharpGLTF.Core 1.0.6 (`LoadGltfScene.cs:15`) and then either builds a `SceneSetup` of `SceneNode`s with transforms, skeletons and animation clips, or, when `CombineBuffer` is set, packs every mesh into one buffer split into chunks ([LoadGltfScene.cs:203-205,232-233](../../visual-programming/tixl/Operators/Lib/Symbols/render/scene/LoadGltfScene.cs)). It reads the five core PBR channels (base color, emissive, metallic-roughness, occlusion, normal; `:604-663`) and no `KHR_materials_*` extension.

| Format | Direction | Mechanism | Citation |
|---|---|---|---|
| glTF (single mesh) | I | SharpGLTF | `Operators/Lib/Symbols/mesh/_/LoadGltf.cs` |
| OBJ | I / E | own `ObjMesh`; `WriteObj` emits the extended `v x y z r g b` form | `Core/Rendering/ObjMesh.cs`, `Operators/Lib/Symbols/mesh/generate/LoadObj.cs:35`, `Operators/Lib/Symbols/io/file/WriteObj.cs:222-236` |
| SVG | I (to points or to texture) | `Svg` 3.4.8 NuGet | `Operators/Lib/Utils/SvgLoader.cs:2-12`, `Operators/Lib/Symbols/point/io/LoadSvg.cs:5,20` |
| DDS | I | JeremyAnsel.Media.Dds | `Core/DataTypes/Texture.cs:74-79` |
| PNG / JPG / BMP / TIFF | I / E | WIC through SharpDX | `Core/DataTypes/Texture.cs:108-110`, `Editor/Gui/Windows/RenderExport/ScreenshotWriter.cs:14-18,103-104` |
| Video | I / E | Sdcb.FFmpeg | `VideoServices/VideoFileEncoder.cs:2,31-41` |

### VL.StandardLibs (vvvv)

Skia does the 2D work: `SVGReader` and `SVGWriter` on SkiaSharp.Svg (`VL.Skia/VL.Skia.vl:46499,46867`), `PDFWriter` on `SKDocument.CreatePdf` (`:50890,51272`), `LottiePlayer (Skia)` on SkiaSharp.Skottie (`VL.Skia/src/VL.Skia.csproj:17`, `.vl:34002`), and image reading and writing through Skia's codecs. 3D import is Stride's `ImportModelCommand`, called at runtime into an in-memory database (`VL.Stride.Runtime/src/Rendering/Models/ModelHelpers.cs:53-82`); the format list lives in the Stride NuGet (Assimp plus the FBX SDK on Windows) and is not verifiable in this tree. Textures load and save through Stride (`TextureExtensions.cs:99-106,147-156,296-305`).

### vello, rend3, wgpu examples

The Rust slice is thin, which is itself the finding.

- **vello** has no SVG in the main crate: `vello_toy` and `vello_bench` use usvg 0.47 (`Cargo.toml:171`, `vello_toy/src/svg.rs:31`), the research scenes carry a tiny `PicoSvg` on roxmltree, and the full integration lives in the separate `vello_svg` repository (`research/vello_research/README.md:144-152`, which also points at `velato` for Lottie). PNG goes through the `png` crate (`vello_common/src/pixmap.rs:250,324`).
- **rend3** reads glTF with the `gltf` crate and declares exactly three extensions: `KHR_lights_punctual`, `KHR_texture_transform` (albedo only) and `KHR_materials_unlit` ([rend3-gltf/src/lib.rs:13-21](../../libraries/rend3/rend3-gltf/src/lib.rs)). KTX2 via `ktx2` 0.3 is raw block formats only, one layer, no Basis transcoding (`:1013-1030,1185`); DDS via `ddsfile` 0.5 (`:1060`); everything else falls back to `image` 0.24 (`:1109`).
- **wgpu** examples use the `obj` crate for the ray-scene example (`examples/features/src/ray_scene/mod.rs:75,120`), `ktx2` 0.5 for the skybox (`skybox/mod.rs:311-318`) and `png` for bunnymark and screenshots. No glTF loader.

### DrawBot

Export-only by design, through macOS frameworks: PDF via a Quartz PDF context (`drawBot/context/pdfContext.py:28-29`), SVG via an own writer (`svgContext.py:230,270`), raster via `NSBitmapImageRep` (`imageContext.py:101-110`), animated GIF via bundled gifsicle, MP4 via bundled ffmpeg (`mp4Context.py:11-17,50`). `image()` reads PDF pages, GIF frames and anything `NSImage` opens (`pdfContext.py:270-288`).

### apEx and werkkzeug4

Both demoscene tools keep projects in their own containers and treat open formats as interchange at the edge. apEx stores whole source image files inside its XML project and decodes them with D3DX at runtime (`apEx/apEx/TexGenParameters.cpp:1010,1041-1049`, `Phoenix/Texgen.cpp:221-235`); mesh import is bundled Assimp into editor meshes (`MeshImport.cpp:23,321,359`); DDS, PNG and TGA export exist for texgen dumps and video frames (`Texgen_tool.cpp:1037`, `VideoDumper.cpp:327-333`). werkkzeug4 serializes `.wz4mesh`, `.wz4tex` and documents through one generic `sLoadObject`/`sSaveObject` streamer (`altona/main/wz4lib/basic_ops.ops:406-429`), with own OBJ load and save (`wz4frlib/wz4_mesh_obj.cpp:18,180`), own XSI and LWO readers, and own image decoders plus stb_image for PNG and JPEG (`altona/main/util/image.cpp:2442-2471,3184-3189`).

---

## What This Means for Flux

1. **USD is readable without Pixar's runtime.** three.js proves a hand-written `.usdc` parser plus a composition engine for references, payloads and variants is tractable in a dynamic language. Babylon proves the opposite trade: ship the real runtime as WASM and flatten. Neither keeps USD as the live scene model; both convert to their own scene graph. See the stance discussion in [`insights/open-formats.md`](../../insights/open-formats.md).

2. **OpenPBR has crossed into realtime, ahead of the registry.** Babylon's native material and its `KHR_materials_openpbr` writer, three.js's `open_pbr_surface` mapping via MaterialX and USD, and Babylon's coat, fuzz, diffuse_roughness and volume_scatter extensions all point the same way: the glTF material model is converging on OpenPBR's lobe structure. None of those four is ratified (they are open pull requests on the glTF repository as of 2026-10-25) and `KHR_materials_openpbr` has no public Khronos proposal; Babylon ships them ahead of ratification and marks the OpenPBR one experimental. A Flux material model that starts from OpenPBR's parameter names will map cleanly onto both sides whenever the registry catches up.

3. **glTF extension coverage is the real differentiator**, not glTF support itself. rend3, orx-dnk3 and tixl each read glTF and each stop at the core PBR model. Filament, three.js and Babylon read ten or more material extensions. Flux's `gltf` crate ships feature flags for ior, specular, transmission, volume, emissive_strength, unlit, variants and pbrSpecularGlossiness but not clearcoat, sheen, iridescence, anisotropy or dispersion (see [`rust-crates.md`](./rust-crates.md)).

4. **Nobody keeps a foreign scene model alive at runtime.** Every project resolves the interchange file into its own structures at load: cables flattens glTF into the patch, Filament's `.filamesh` tool and werkkzeug4 bake to their own containers, Babylon's USD path flattens inside the WASM worker, and three.js composes USD and then builds a three.js scene. tixl is the one that lets the user choose: `LoadGltfScene` keeps the node hierarchy with transforms, skeletons and clips by default and flattens into one chunked buffer only when `CombineBuffer` is set, and even the hierarchy is tixl's own `SceneSetup`, not glTF's. That switch is a good operator design to copy.

5. **PDF is always borrowed; SVG is written by hand.** Cairo, Skia, Batik, iText and Quartz write every PDF in this survey. SVG, being text, gets a hand-written writer in three.js (`SVGRenderer`), PixiJS (`graphicsContextToSvg`), openFrameworks (`ofxSvg::save`), orx and DrawBot. The Rust answer (krilla or pdf-writer for PDF, the `svg` crate for SVG) exists but no studied framework has used it yet.

---

## Commits Read

| Submodule | Commit | Notes |
|---|---|---|
| `libraries/web/threejs` | `628bf37748e` | r184 line |
| `libraries/web/babylonjs` | `39d7f0e152e` | 9.30.0 line |
| `libraries/web/pixijs` | `65552017d23` | v8.22.0 line |
| `visual-programming/cables` | `f294f9e6ee2` | |
| `frameworks/p5js` | `6fb945f72b7` | v1.11.14-rc.2 line |
| `libraries/cpp/filament` | `97d16d9f127` | |
| `frameworks/openframeworks` | `f9e8d959fc8` | |
| `frameworks/cinder` | `f90f332d1a4` | |
| `frameworks/processing` | `be0ee8266e07` | `libprocessing/` not checked out |
| `frameworks/openrndr` | `00c47af75ddc` | |
| `libraries/openrndr-ecosystem/orx` | `3d3ada30bae` | |
| `frameworks/nannou` | `bffa9887b18` | |
| `frameworks/drawbot` | `71cff6df68f` | |
| `visual-programming/tixl` | `10d2d7ea348` | |
| `libraries/vvvv-ecosystem/VL.StandardLibs` | `41aa0e507705` | |
| `libraries/rust/vello` | `65338c258f09` | |
| `libraries/rend3` | `d088a841b046` | |
| `libraries/rust/wgpu` | `14328f49918` | |
| `demoscene/apex-public` | `fff9223ff225` | |
| `demoscene/fr_public` | `8c8f82c2ae01` | |

Surveyed 2026-10-25. Rows marked (x) for Assimp or Stride describe a bundled importer whose format list is not in this tree.
