# Operator Family Inventory: OpenFrameworks

## Framework overview

OpenFrameworks is a C++ immediate-mode creative-coding toolkit organized as a thin "glue" core (`libs/openFrameworks/`) plus a sprawling community-driven addon ecosystem (`ofx*` directories under `addons/`). It is not a node graph and has no operator catalog per se, but its core module layout (`3d/`, `sound/`, `video/`, `communication/`, `events/`, `gl/`) and its bundled official addons (`ofxOsc/`, `ofxNetwork/`, `ofxOpenCv/`, `ofxKinect/`, `ofxAssimp/`, `ofxGui/`, `ofxSvg/`, `ofxXmlSettings/`, `ofxAccelerometer/`, `ofxGPS/`, `ofxPoco/`) read as the de-facto checklist of "what real-world creative-coding projects actually plug into." Its strongest contribution to a flux inventory is **real-world I/O**: audio capture / analysis, MIDI-adjacent serial protocols, OSC, TCP/UDP, depth sensors, accelerometer/GPS, computer vision, and skinned-mesh asset import — categories that pure visual-programming references (Tooll3, cables, vvvv) often under-represent.

## Families

### Audio I/O (capture, playback, buffers) [scene] [authoring]
- **Description:** Realtime audio input/output with sample buffers, sample-rate / channel negotiation, and per-block callbacks.
- **Representative addons/APIs:** `libs/openFrameworks/sound/ofSoundStream.h`, `ofRtAudioSoundStream.h`, `ofSoundBuffer.h`, `ofSoundPlayer.h`, `ofOpenALSoundPlayer.h`, `ofAVEngineSoundPlayer.h` (macOS), `ofMediaFoundationSoundPlayer.h` (Windows); examples `examples/sound/audioInputExample/`, `audioOutputExample/`, `soundBufferExample/`.
- **Why it matters:** Audio-reactive visuals are a foundational creative-coding workload; without an audio-input operator family flux cannot author live-music visuals, generative soundscapes, or even VU-meter overlays. Visual-programming refs in this study tend to expose only audio playback, not capture+blocks.
- **Likely missing from flux:** confirmed missing

### Audio Analysis (FFT, spectrum, level) [scene] [authoring]
- **Description:** Per-frame frequency-domain analysis of audio buffers — FFT, spectrum bands, RMS / level, beat-adjacent metrics.
- **Representative addons/APIs:** `ofSoundPlayer` exposes `getSpectrum(int bands)` and `getCurrentRMS*()`; example `examples/sound/soundPlayerFFTExample/`. Third-party community addons (`ofxAudioAnalyzer`, `ofxFft`, `ofxAubio`) extend this; not vendored here but referenced in the addon culture.
- **Why it matters:** Spectrum bands are the primary control signal for audio-reactive scenes (VJ, music visualisation, generative installations). Without an analysis operator the only path is to author DSP in WGSL or hand-roll a CPU FFT op.
- **Likely missing from flux:** confirmed missing

### Video Capture (webcam, capture devices) [scene]
- **Description:** Live video frames from camera/capture devices, with backend per OS (AVFoundation, DirectShow, GStreamer).
- **Representative addons/APIs:** `libs/openFrameworks/video/ofVideoGrabber.h`, `ofAVFoundationGrabber.h`, `ofDirectShowGrabber.h`, `ofGstVideoGrabber.h`; addon backends `addons/ofxAndroid/src/ofxAndroidVideoGrabber.h`, `addons/ofxEmscripten/src/ofxEmscriptenVideoGrabber.h`; example `examples/video/videoGrabberExample/`.
- **Why it matters:** Webcam input is a baseline for interactive installations and CV pipelines; flux's source list calls this out as missing.
- **Likely missing from flux:** confirmed missing

### Video Playback (file decode, streaming) [scene]
- **Description:** Decoding video files to texture/pixel frames each tick, with seek and rate control.
- **Representative addons/APIs:** `ofVideoPlayer.h`, `ofGstVideoPlayer.h`, `ofAVFoundationPlayer.h`, `ofMediaFoundationPlayer.h`; example `examples/video/videoPlayerExample/`, `slitscanRadialClockExample/`.
- **Why it matters:** Looped-clip backgrounds, slit-scan effects, and reference footage all need a video source operator. Visual refs (Tooll3, cables) cover this; flux does not.
- **Likely missing from flux:** confirmed missing

### OSC (Open Sound Control) [authoring]
- **Description:** Bidirectional UDP-based control protocol used to bridge audio software (Ableton, Max, SuperCollider, TouchOSC), lighting consoles, and external controllers into the scene.
- **Representative addons/APIs:** `addons/ofxOsc/src/ofxOscSender.h`, `ofxOscReceiver.h`, `ofxOscMessage.h`, `ofxOscBundle.h`, `ofxOscParameterSync.h`; bundled `oscpack` library at `addons/ofxOsc/libs/oscpack/`; examples `examples/communication/oscSenderExample/`, `oscReceiveExample/`, `oscChatSystemExample/`, `oscOptionalExample/`.
- **Why it matters:** OSC is the lingua franca of cross-application creative tooling — without an OSC receiver flux cannot accept control input from any external surface. Visual-programming refs treat this as a core I/O family.
- **Likely missing from flux:** confirmed missing

### Network I/O (TCP / UDP, HTTP) [scene] [authoring]
- **Description:** Raw socket primitives (TCP server/client, UDP send/receive) plus HTTP fetch.
- **Representative addons/APIs:** `addons/ofxNetwork/src/ofxTCPServer.h`, `ofxTCPClient.h`, `ofxTCPManager.h`, `ofxUDPManager.h`, `ofxTCPSettings.h`, `ofxUDPSettings.h`; HTTP via core `libs/openFrameworks/utils/ofURLFileLoader.h`; examples `examples/communication/networkTcpServerExample/`, `networkUdpReceiverExample/`.
- **Why it matters:** Multi-machine installations (projection arrays, sync-paired displays) and live data feeds need raw network sockets and HTTP polling; node-graph refs rarely treat this as first-class.
- **Likely missing from flux:** confirmed missing

### Serial / Hardware Bus (Arduino, microcontrollers) [scene] [authoring]
- **Description:** Byte-stream serial I/O and the Firmata protocol for talking to Arduino-class microcontrollers (digital/analog pins, servos).
- **Representative addons/APIs:** `libs/openFrameworks/communication/ofSerial.h`, `ofArduino.h`; example `examples/communication/serialExample/`, `firmataExample/`.
- **Why it matters:** Physical-computing installations (sensors, motors, lights, custom controllers) depend on serial; this is the canonical "creative-coding-meets-hardware" channel and is a hard gap to plug after the fact.
- **Likely missing from flux:** confirmed missing

### Depth / Skeleton Sensors [scene]
- **Description:** Depth-camera streams (depth + RGB + skeleton joints) for body/hand tracking and 3D capture.
- **Representative addons/APIs:** `addons/ofxKinect/src/ofxKinect.h`, `ofxBase3DVideo.h`, vendored `libfreenect` under `addons/ofxKinect/libs/`; example `examples/computer_vision/kinectExample/`.
- **Why it matters:** Body-tracked installations, gesture interfaces, and volumetric capture all start here. OF is the most-cited reference for this family — visual refs cover it inconsistently.
- **Likely missing from flux:** confirmed missing

### Mobile Sensors (Accelerometer, GPS, Touch) [scene]
- **Description:** On-device sensor streams from phones and SBCs — orientation, motion, geolocation, multitouch.
- **Representative addons/APIs:** `addons/ofxAccelerometer/src/ofxAccelerometer.h`; `addons/ofxGPS/src/{Android,iOS,common}/`; touch via `addons/ofxAndroid/`, `addons/ofxiOS/src/events/`.
- **Why it matters:** Cross-platform deployment to mobile / kiosk hardware needs sensor operators. Probably out-of-scope for a Decima-class desktop target but worth flagging — flux currently has no `MobileSensor`-shaped abstraction at all.
- **Likely missing from flux:** probably missing (out of immediate scope but blocks mobile deploys)

### Computer Vision (image processing, blob tracking, features) [scene]
- **Description:** CPU-side image-processing pipeline — thresholding, blob/contour detection, Haar cascade face/object detection, optical flow, classification.
- **Representative addons/APIs:** `addons/ofxOpenCv/src/ofxCvImage.h`, `ofxCvGrayscaleImage.h`, `ofxCvColorImage.h`, `ofxCvFloatImage.h`, `ofxCvContourFinder.h`, `ofxCvHaarFinder.h`, `ofxCvBlob.h`; examples `examples/computer_vision/opencvExample/`, `opencvHaarFinderExample/`, `opencvOpticalFlowExample/`, `opencvPeopleDetection/`, `opencvImageClassification/`.
- **Why it matters:** Interactive installations frequently need cv pipelines (silhouette extraction, presence detection, marker tracking) ahead of any GPU compositing. Cv is one of the largest single-addon families in OF and is consistently under-represented in visual-programming refs.
- **Likely missing from flux:** confirmed missing

### Mesh / Scene Asset Import (glTF / FBX / OBJ via Assimp) [scene]
- **Description:** Loaded-mesh import with skinning, materials, animation tracks, scene hierarchy.
- **Representative addons/APIs:** `addons/ofxAssimp/src/ofxAssimpScene.h`, `ofxAssimpMesh.h`, `ofxAssimpAnimation.h`, `ofxAssimpAnimationMixer.h`, `ofxAssimpSkeleton.h`, `ofxAssimpBone.h`, `ofxAssimpTexture.h`; legacy `addons/ofxAssimpModelLoader/src/ofxAssimpModelLoader.h`.
- **Why it matters:** Without a loaded-mesh path flux is locked to procedural primitives; the brief already flags this as deferred. Notable: ofxAssimp ships an `AnimationMixer` (blending between named clips), which is the gateway to a skeletal-animation family.
- **Likely missing from flux:** confirmed missing (asset-loading substrate exists, mesh decoder + skinning do not)

### Skeletal Animation / Skinning [scene] [visual]
- **Description:** Bone hierarchy, skin-cluster vertex weighting, named clips, blend-tree-adjacent animation mixing.
- **Representative addons/APIs:** `addons/ofxAssimp/src/ofxAssimpSkeleton.h`, `ofxAssimpBone.h`, `ofxAssimpAnimation.h`, `ofxAssimpAnimationMixer.h`; legacy `addons/ofxAssimpModelLoader/src/ofxAssimpAnimation.h`.
- **Why it matters:** Decima-class scenes are character-driven; OF surfaces the minimum surface area (skeleton + clip + mixer). Brief flags as "none" in flux.
- **Likely missing from flux:** confirmed missing

### Vector Graphics / SVG [authoring] [visual]
- **Description:** Read/write SVG, vector-path representation, PostScript-style 2D drawing, CSS-styled vector documents.
- **Representative addons/APIs:** `addons/ofxSvg/src/ofxSvg.h`, `ofxSvgElements.h`, `ofxSvgCss.h`, `ofxSvgFontBook.h`, `ofxSvgGroup.h`; legacy `addons/ofxVectorGraphics/src/ofxVectorGraphics.h` (CreativeCommons-style PostScript output); core `libs/openFrameworks/graphics/ofPath.h`, `ofPolyline.h`, `ofCairoRenderer.h`; examples `examples/input_output/svgExample/`, `svgParseExample/`, `svgSaveExample/`, `pdfExample/`.
- **Why it matters:** Print-quality output, sign-painting / generative-poster pipelines, and parametric logo work depend on vector paths as a first-class type alongside raster textures. Tools like cables/Tooll under-cover this.
- **Likely missing from flux:** confirmed missing

### Typography / Font Rendering [visual] [authoring]
- **Description:** TrueType glyph layout, kerning, bitmap fallback, vector outlines for typography.
- **Representative addons/APIs:** `libs/openFrameworks/graphics/ofTrueTypeFont.h`, `ofBitmapFont.h`; SVG font book at `addons/ofxSvg/src/ofxSvgFontBook.h`; example `examples/graphics/fontsExample/`, `fontShapesExample/`.
- **Why it matters:** Even AAA UIs need glyph rendering, and creative-coding work disproportionately leans on type. Flux has nothing in this family.
- **Likely missing from flux:** confirmed missing

### Structured Data I/O (XML, JSON, CSV) [authoring]
- **Description:** Parse and emit structured config / dataset files at runtime.
- **Representative addons/APIs:** `libs/openFrameworks/utils/ofXml.h`, `ofJson.h`; `addons/ofxXmlSettings/src/ofxXmlSettings.h`; `addons/ofxPoco/src/ofxXmlPoco.h`; examples `examples/input_output/jsonExample/`, `xmlExample/`, `xmlSettingsExample/`, `fileBufferLoadingCSVExample/`.
- **Why it matters:** Data-driven scenes (CSV-fed visualisations, JSON-feed dashboards, XML preset libraries) need parsed-data operators at the graph level, not just shader uniforms.
- **Likely missing from flux:** confirmed missing

### File / Filesystem I/O [authoring]
- **Description:** File listing, drag-drop, dialogs, clipboard, image save/load, threaded image loaders, image sequences.
- **Representative addons/APIs:** `libs/openFrameworks/utils/ofFileUtils.h`, `ofSystemUtils.h`; `addons/ofxThreadedImageLoader/src/ofxThreadedImageLoader.h`; examples `examples/input_output/dirListExample/`, `dragDropExample/`, `fileOpenSaveDialogExample/`, `clipboardExample/`, `imageSequenceExample/`, `imageSaverExample/`, `imageCompressionExample/`.
- **Why it matters:** Authoring-tool ergonomics (load-via-drop, image-sequence playback for offline-rendered clips, save dialogs for exports) are graph-level operations, not shell concerns. Image-sequence playback is also the standard offline-render input pipeline.
- **Likely missing from flux:** partial (file-watcher / asset cache exist; drag-drop, sequence playback, save dialog, clipboard do not)

### Parameters / GUI Panel [authoring]
- **Description:** Typed parameter objects with min/max/default that auto-bind to sliders, toggles, color pickers, and grouped panels; serializable to/from disk.
- **Representative addons/APIs:** `libs/openFrameworks/types/ofParameter.h`, `ofParameterGroup.cpp`; `addons/ofxGui/src/ofxPanel.h`, `ofxSlider.h`, `ofxToggle.h`, `ofxColorPicker.h`, `ofxInputField.h`, `ofxSliderGroup.h`; OSC-sync at `addons/ofxOsc/src/ofxOscParameterSync.h`.
- **Why it matters:** This is the closest OF gets to flux's "operator port" abstraction — typed value with metadata, auto-bound UI, serializable. Worth studying as a *pattern* even though flux's port system covers most of it; the OSC-sync mirror is the interesting cross-family piece (parameter values mirrored over OSC bidirectionally).
- **Likely missing from flux:** partial (ports cover the type/default story; explicit panel grouping, range metadata, and parameter-OSC mirroring are not exposed)

### Event System (input + lifecycle) [scene] [authoring]
- **Description:** Mouse / keyboard / touch / window / app-lifecycle events delivered through a typed listener system; also custom user events.
- **Representative addons/APIs:** `libs/openFrameworks/events/ofEvents.h`, `ofEvent.h`, `ofEventUtils.h`; examples `examples/events/allEventsExample/`, `customEventExample/`, `notifyEventExample/`, `simpleTimerEventExample/`, `rpiTouchExample/`.
- **Why it matters:** Mouse / keyboard / touch / gamepad input is called out as missing in flux's inventory. Beyond pointer events, OF's pattern of dispatching app-lifecycle (setup/update/draw/exit) and timer events through the same channel is worth noting — flux's per-frame eval model needs an analogous "discrete event" surface for triggers, button-down, key-press, etc.
- **Likely missing from flux:** confirmed missing

### Threading / Async Work [scene]
- **Description:** Background worker threads with thread-safe message channels for offloading IO/decoding work without stalling the render loop.
- **Representative addons/APIs:** `libs/openFrameworks/utils/ofThread.h`, `ofThreadChannel.h`; `addons/ofxThreadedImageLoader/`; example `examples/gl/threadedPixelBufferExample/`.
- **Why it matters:** Asset streaming (a Tier-1 AAA concern called out in the brief) is unsolvable without async-worker primitives surfaced at the graph level. OF surfaces this as an explicit `ofThread` base plus thread-safe channels — a flux operator-graph needs an equivalent affordance for non-blocking asset loads and decoder jobs.
- **Likely missing from flux:** probably missing at the operator level (substrate may exist below)

## Notable patterns (not operators)

- **Addon distribution model** — Every `ofx*` directory is self-contained: `src/`, optional `libs/` for vendored deps (`addons/ofxOsc/libs/oscpack/`, `addons/ofxKinect/libs/libfreenect/`), `addon_config.mk` for build wiring. A flux analog ("operator-pack distribution") would let third-party I/O families ship without core-crate churn.
- **`ofMain.h` umbrella include** — `libs/openFrameworks/ofMain.h` is a single header that pulls everything. The cost is silent global namespace pollution; the benefit is zero-config beginner ergonomics. Worth being explicit about how flux wants to balance discoverability vs explicit dependencies in `use` paths.
- **`ofEvents` listener pattern** — `libs/openFrameworks/events/ofEvents.h` exposes a global event bus for mouse/keyboard/window/app-lifecycle. Different from flux's pull-evaluated graph, but a model for how *discrete* (non-per-frame) signals fit into a system whose main loop is per-frame `update()`+`draw()`.
- **App lifecycle (`setup` / `update` / `draw` / `exit`)** — The 4-callback contract in `libs/openFrameworks/app/ofBaseApp.h` is the C++-creative-coding analog to flux's preload / per-frame eval. Notable that OF treats `setup` (one-time) and `update` (per-frame) as siblings — flux's recent pre-load phase mirrors this.
- **`ofParameter` model** — `libs/openFrameworks/types/ofParameter.h` is the strongest pattern overlap with flux's typed ports: a value with a name, min/max, default, change-event, and auto-UI. The interesting extension is `ofxOscParameterSync` (`addons/ofxOsc/src/ofxOscParameterSync.h`): the *same* parameter object is auto-mirrored over OSC bidirectionally. A flux equivalent would be "any port is OSC-addressable by path" — a free remote-control surface.
- **Per-OS backend split with shared base interface** — sound/video have parallel backends (`ofRtAudioSoundStream` / `ofAVEngineSoundPlayer` / `ofMediaFoundationSoundPlayer`; `ofAVFoundationGrabber` / `ofDirectShowGrabber` / `ofGstVideoGrabber`) behind a common base type. Pattern flux will need if it ever moves past wgpu's single-backend abstraction for any I/O family.

## Sources cited

- `research/operator-families-research-brief.md`
- `notes/per-framework/openframeworks/README.md`
- `frameworks/openframeworks/libs/openFrameworks/` (subdirs: `3d/`, `app/`, `communication/`, `events/`, `gl/`, `graphics/`, `math/`, `sound/`, `types/`, `utils/`, `video/`)
- `frameworks/openframeworks/addons/` (ofxAccelerometer, ofxAndroid, ofxAssimp, ofxAssimpModelLoader, ofxEmscripten, ofxGPS, ofxGui, ofxKinect, ofxNetwork, ofxOpenCv, ofxOsc, ofxPoco, ofxSvg, ofxThreadedImageLoader, ofxUnitTests, ofxVectorGraphics, ofxXmlSettings, ofxiOS)
- `frameworks/openframeworks/examples/` (communication, computer_vision, events, gl, graphics, input_output, shader, sound, video)
