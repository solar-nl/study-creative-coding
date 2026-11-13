# The Harfang 3D Rendering Pipeline

> Harfang renders a frame by handing out numbered tickets. Every pass takes a bgfx view id, does its work, and increments the counter. The scene never knows which pass it is in; the pass only knows which shader permutation to ask for.

All paths and line numbers refer to commit `abc8fc5de961` (v3.2.7) of `frameworks/harfang3d`, with the nested bgfx submodule at `3d4bd88c0635`. Paths are relative to `harfang/` unless they start with `extern/`, `binding/` or `tools/`, or are the repository-root `CMakeLists.txt`.

## Key Insight

> **Harfang's rendering idea:** a frame is a sequence of bgfx views, one per pass, numbered by a counter that every submit function takes by reference and advances. Materials pick a shader permutation from which textures they carry; passes pick a pipeline configuration from which lights cast shadows. The two indices multiply into one precompiled program per (material permutation, pass).

---

## Scope: Where This Trace Stops

This document follows a scene from `SubmitSceneToPipeline` to `bgfx::submit`. It does not go into the shaders, because the checkout contains none: shader programs arrive as precompiled `.vsb` and `.fsb` files from the asset tree (`engine/render_pipeline.cpp:621-624`) and the GLSL sources that produce them live in Harfang's shader package, not in this repository. The C++ side still reveals two things about the GPU side: which preprocessor defines each pass compiles with, and which uniforms and sampler stages the shaders read. Both are cited where they matter (`engine/forward_pipeline.cpp:395-416`, `:446-491`).

The bgfx behavior this document leans on, that views execute in id order and sort draws within a view, is verified against the bgfx source at the pinned commit (`extern/bgfx/bgfx/src/bgfx_p.h:956-957`, `:1112`; `src/bgfx.cpp:1445-1450`). The nested submodule was initialized for this trace.

---

## The Problem: One Scene, Two Quality Tiers, Five Backends, Three Languages

Here is the job. You have a retained scene of nodes with transforms, objects, lights and a camera. You need to draw it on Vulkan, Metal, Direct3D, OpenGL and WebGL 2 without writing five renderers. You need a cheap path for an ARM dashboard and an expensive path with screen-space GI, reflections and temporal anti-aliasing for a marketing render, and the same scene file must feed both. And the whole thing must be callable from Python inside someone else's loop, so there can be no renderer object with virtual methods and no callbacks.

The backend problem has a known answer, bgfx, and Harfang takes it whole: no abstraction of its own sits between the engine and bgfx. `bgfx::ViewId`, `bgfx::ProgramHandle`, `bgfx::TextureHandle` and `bgfx::FrameBufferHandle` appear in the public headers unwrapped (`engine/render_pipeline.h:67-79`, `:248-251`). The binding even exposes `bgfx::frame` to Python as `hg.Frame()` (`binding/bind_harfang.py:2150`).

The other two problems are what the engine actually solves, and it solves both with indices rather than objects. This document is mostly about those two indices and the frame structure that consumes them.

---

## The Mental Model: Tickets, Buckets and Two Dials

Think of a bgfx frame as a row of numbered buckets, 256 of them by default (`extern/bgfx/bgfx/src/config.h:256-258`). A draw call goes into one bucket. When the frame ends, bgfx empties the buckets in numerical order, and within each bucket it sorts the draws by a key whose top ten bits are the bucket number (`bgfx_p.h:956-957`; the encoding at `:1112` puts view first, then program or depth depending on the view mode). A bucket can have its own framebuffer, viewport, clear flags and view-projection matrices. That is a bgfx "view".

Harfang's pipeline is a ticket dispenser for those buckets: a ticket is simply the number of the bucket a pass will fill. Every pass function takes `bgfx::ViewId &view_id`, configures bucket `view_id`, submits its draws there, and does `view_id++` before returning (`engine/scene_forward_pipeline.cpp:650`, `:767`, `:795`; `engine/taa.cpp:68`). The caller starts at zero each frame and never has to know how many buckets a pass needed. A pass that needed four, like the cascaded shadow map, takes four tickets (`engine/forward_pipeline.cpp:341`). The pipeline hands back an array meant to record which ticket each named pass got, `SceneForwardPipelinePassViewId` (`engine/scene_forward_pipeline.h:165-180`), so a caller who wants to draw debug lines into the opaque pass can find its view id. In practice only the scene passes survive in it; the shadow entries are lost on the way (see the gotchas).

Inside a bucket, two dials decide which GPU program draws a given mesh:

1. **The material's variant index.** Which optional textures and flags this material has. Computed once per material from its texture names (`render_pipeline.cpp:892-939`).
2. **The pass's configuration index.** Which of ten pipeline configurations this pass is: attribute prepass, basic lighting with 0 to 2 shadow casters, AAA lighting with 0 to 2 shadow casters, or depth only (`forward_pipeline.cpp:395-416`, selected at `scene_forward_pipeline.cpp:501-522`).

The program is `programs[variant * 10 + config]`, loaded on first use from a file whose name spells out both numbers (`render_pipeline.cpp:2009-2032`). That is the whole shader system. The rest of this document traces one frame through it, first on the basic path, then on the AAA path.

---

## Tracing `SubmitSceneToPipeline`: The Basic Path in Nine Stages

The high-level entry point is short (`scene_forward_pipeline.cpp:950-956`): build render data, cull it for this view, submit. From Python the call is `view_id, views = hg.SubmitSceneToPipeline(view_id, scene, rect, True, pipeline, res)`; the binding marks `view_id` as in-out and `views` as out (`binding/bind_harfang.py:1572-1573` for this overload, `:1569-1570` for the one taking an explicit view state).

| # | Stage | Input | Output | Location |
|---|-------|-------|--------|----------|
| 1 | Flatten the scene | Live nodes with Transform and Object | Four display-list arrays: opaque, transparent, and the skinned versions of each | `engine/scene.cpp:318-404` |
| 2 | Assign light slots | Enabled lights | 8 slots of packed `Vec4` uniforms; slot 0 is the brightest-priority linear light | `engine/forward_pipeline.cpp:90-135` |
| 3 | Spot shadow map | Slot 1 light, all opaque lists | One view into `spot_shadow_map`, `spot_shadow_mtx`; takes the first ticket | `forward_pipeline.cpp:348-392` |
| 4 | Cascaded shadow map | Slot 0 light, camera view state, all opaque lists | Four views into the `linear_shadow_map` atlas, four crop matrices; the next four tickets | `forward_pipeline.cpp:217-345` |
| 5 | Frustum cull | View frustum, opaque and transparent lists | `view_opaque`, `view_transparent` (skinned lists copied uncull) | `scene_forward_pipeline.cpp:555-562`, `render_pipeline.cpp:2098-2104` |
| 6 | Upload pipeline uniforms | Lights, fog, ambient, shadow data | 23 named uniform values, 8 sampler stages | `forward_pipeline.cpp:138-164`, `:446-491` |
| 7 | Opaque view | `view_opaque`, config index | One bgfx view, default sort | `scene_forward_pipeline.cpp:899-923` |
| 8 | Transparent view | `view_transparent`, per-list depth keys | One bgfx view, `DepthDescending` | `scene_forward_pipeline.cpp:925-946`, `:438-484` |
| 9 | Per display list | Material, config index | Program lookup, uniforms, `bgfx::submit` | `render_pipeline.cpp:2035-2074`, `:1910-1919` |

Then the host calls `hg.Frame()`, which is `bgfx::frame()`, and bgfx sorts and executes every bucket (`extern/bgfx/bgfx/include/bgfx/bgfx.h:2029`). Stages 1, 2, 5 and 6 are CPU-side data work. Stages 3, 4, 7, 8 and 9 record bgfx views and draws, and the shadow passes take their tickets first: the spot pass runs in the common preparation and the cascades in the view-dependent one (`scene_forward_pipeline.cpp:534-538`, `:546-553`), both before the opaque view. Nothing reaches the GPU until the host ends the frame.

### A worked frame

Take a small scene: a directional light with shadows, a spot light with shadows, two opaque meshes on a PBR program (one with a normal map), one glass mesh, and a camera. Starting from `view_id = 0`, here is what the dispenser hands out:

| Ticket | Pass | Configuration | Why |
|--------|------|---------------|-----|
| 0 | Spot shadow map | 9 (`DEPTH_ONLY`) | Slot 1 holds the spot light (`forward_pipeline.cpp:357-359`) |
| 1, 2, 3, 4 | Cascades 0 to 3 | 9 | Slot 0 holds a linear light with `FPST_Map` (`:226-231`), one ticket per split (`:341`) |
| 5 | Opaque | 1 + 0b11 = 4 (`FORWARD_PIPELINE`, `SLOT0_SHADOWS`, `SLOT1_SHADOWS`) | Both shadow slots are set (`scene_forward_pipeline.cpp:508-516`) |
| 6 | Transparent | 4 | Same configuration, `DepthDescending` sort |

`views[SFPP_Opaque]` comes back as 5 and `view_id` as 7. Remove the spot light's shadow flag and the ticket layout does not change, because the spot pass checks only that slot 1 holds a light; the opaque configuration drops to 1 + 0b01 = 2. Remove the spot light itself and the cascades move to tickets 0 to 3, the opaque view to 4, and the configuration drops to 1 + 0b01 = 2.

For the program each mesh draws with, suppose the PBR program's feature file lists `OptionalBaseColorOpacityMap`, `OptionalOcclusionRoughnessMetalnessMap`, `OptionalNormalMap`, `OptionalSkinning` and `OptionalAlphaCut` in that order (the shader package is not in the checkout, so this list is illustrative). The normal-mapped mesh has only `uNormalMap` set, giving feature states `[0, 0, 1, 0, 0]`, variant index 4 (`render_pipeline.cpp:866-876`), and in ticket 5 it asks for `pbr_var-4_pipe-forward-cfg-4.vsb` and `.fsb`. The untextured mesh is variant 0 and asks for `pbr_var-0_pipe-forward-cfg-4`. In the shadow tickets both ask for the `cfg-9` versions of their own variants.

### Stage 1: a scene becomes four flat lists

`Scene::GetModelDisplayLists` walks every node once. It skips disabled nodes and nodes without a transform or an object (`scene.cpp:330-340`), then for each of the model's display lists (one per material slot) it emits a 16-byte record:

**File:** `engine/render_pipeline.h:577-582`

```cpp
struct ModelDisplayList { // 16B
	const Material *mat; // 8
	uint32_t mtx_idx; // 4
	uint16_t mdl_idx; // 2
	uint16_t lst_idx; // 2
};
```

`mtx_idx` is the transform's slot index, which indexes straight into the scene's world-matrix vector (see the [architecture document](./architecture.md)). `mdl_idx` and `lst_idx` locate the GPU buffers in `PipelineResources`. The opaque-or-transparent decision is one line: a material whose blend mode is anything but `BM_Opaque` is transparent (`scene.cpp:357`). Objects with a valid skin go to the skinned lists instead, which carry up to 32 bone matrix indices each (`render_pipeline.h:596-603`; the 32 is `max_skinned_model_matrix_count`, `:38`, matching bgfx's shader-side `BGFX_CONFIG_MAX_BONES` of 32, `extern/bgfx/bgfx/src/bgfx_shader.sh:9-11`).

This is the only place rendering touches the scene's structure. Everything after works on these arrays.

### Stage 2: eight light slots, packed

The forward pipeline has exactly eight light slots (`forward_pipeline.h:22`), and `PrepareForwardPipelineLights` fills them by priority: the highest-priority linear (directional) light takes slot 0, then point and spot lights take slots 1 to 7 in priority order, and the rest are dropped (`forward_pipeline.cpp:104-132`). The packing is worth seeing because it is the kind of thing a shader-less reader would otherwise never learn:

**File:** `engine/forward_pipeline.cpp:124-127`

```cpp
ls.pos[slot_idx] = Vec4(GetT(l.world), l.radius ? 1.f / l.radius : 0.f);
ls.dir[slot_idx] = Vec4(GetZ(l.world), l.type == FPLT_Spot ? Cos(l.inner_angle) : 0.f);
ls.diff[slot_idx] = {l.diffuse.r, l.diffuse.g, l.diffuse.b, l.type == FPLT_Spot ? Cos(l.outer_angle) : 0.f};
ls.spec[slot_idx] = {l.specular.r, l.specular.g, l.specular.b, 0.f};
```

Position carries inverse radius in `w`, direction carries the inner cone cosine, diffuse carries the outer cone cosine. Four `Vec4[8]` uniforms describe the whole lighting rig (`:454-457`).

### Stages 3 and 4: two shadow maps, two owners

Only slots 0 and 1 can cast shadows, and they get different treatment. Slot 1, a spot light, renders once per frame into a single `res x res` depth texture, 16-bit by default (`forward_pipeline.cpp:428-429`), from a fixed 0.1 to 100 metre perspective (`:365`). It is view-independent, so it runs in the "common" preparation (`scene_forward_pipeline.cpp:534-538`).

Slot 0, the directional light, renders four parallel-split cascades into one `2res x 2res` 32-bit atlas (`:426-427`), one quadrant per split, with the quadrant offset folded into the shadow matrix (`:307-308`, `:318-319`). The split distances come from the light's `pssm_split` vector, the light position is snapped to shadow-map texels so the cascade does not shimmer as the camera moves (`:294-296`), and each cascade culls the opaque list against its own frustum before drawing with configuration 9, depth only (`:331-335`). This depends on the camera, so it runs in the "view-dependent" preparation (`scene_forward_pipeline.cpp:546-553`). Both maps are bound with hardware depth compare (`BGFX_SAMPLER_COMPARE_LEQUAL`, `forward_pipeline.cpp:489-490`).

There is no point-light shadow path, no cube map, and the pipeline configuration table has exactly two shadow flags, `SLOT0_SHADOWS` and `SLOT1_SHADOWS` (`:402-411`). The code does not stop a point light from taking slot 1 with shadows enabled, though: `GetSceneForwardPipelineLights` copies `LST_Map` for any light type (`scene_forward_pipeline.cpp:423-428`), and the spot pass would then run with the point light's zero outer angle as its field of view (`:416-420`, `forward_pipeline.cpp:365`). I have not run this; expect a degenerate frustum.

One reading of the code, not confirmed by running it: the linear pass returns early when slot 0 has no shadows (`:230-231`), but the spot pass checks only that slot 1 holds a light (`:358-359`), not its shadow type. Since the first point or spot light by priority always lands in slot 1 (`:117-132`), any scene with at least one point or spot light pays for a spot shadow pass, a full depth render of every opaque list, even when no light has shadows enabled. Whether the resulting map is sampled only under the `SLOT1_SHADOWS` configuration is a shader question this checkout cannot answer. **The cost is readable from the code; the waste is untested.**

### Stage 5: culling, with a gap

Culling is an AABB-against-frustum test per display list (`render_pipeline.cpp:2098-2104`), using the model's per-list bounds transformed by the node matrix. Skinned lists are copied through uncull with a `FIXME` (`scene_forward_pipeline.cpp:560-562`), in the main view and in every shadow cascade (`forward_pipeline.cpp:337`, `:386`).

### Stages 7 and 8: two buckets, two sort modes

The opaque view uses bgfx's default sort, which orders draws within a view by blend state, then program, then depth (`bgfx_p.h:1116-1122`, the `SortProgram` key). Harfang passes depth 0 for every opaque draw (`render_pipeline.cpp:2135`, the `depths ? ... : 0` branch), so opaque draws are grouped by shader and otherwise left in submission order. There is no front-to-back sort for early-z.

The transparent view sets `bgfx::ViewMode::DepthDescending` (`scene_forward_pipeline.cpp:933`; bgfx's enum at `extern/bgfx/bgfx/include/bgfx/bgfx.h:381-393`) and computes a depth key per display list. It transforms the eight AABB corners into view space and takes the nearest `z` (`:455-474`). It clamps that at zero (`:476-477`). Then `ComputeSortKey` adds 100 metres and quantizes to millimetres (`render_pipeline.cpp:89-94`). Descending order on that key is back to front. The offset was meant to let objects slightly behind the camera sort, but on this path the clamp runs first, so every transparent object whose nearest corner is behind the camera shares one key and draws in submission order. `ComputeSortKeyFromWorld` (`:96-97`) skips the clamp and does get the benefit. Skinned transparent lists all get key 0 (`:493-496`, marked `TODO`), so they draw in submission order among themselves.

### Stage 9: from a material to `bgfx::submit`

Here is where the two dials meet. For each display list, `_RenderPipelineStageDisplayList` (`render_pipeline.cpp:2035-2074`) does four things:

1. Asks the material's pipeline program for the variant-and-configuration program, loading it from disk on first request. The file name is the two indices spelled out:

   **File:** `engine/render_pipeline.cpp:2020`

   ```cpp
   const std::string path = format("%1_var-%2_pipe-%3-cfg-%4").arg(pprg.name).arg(variant_idx).arg(pprg.pipeline.name).arg(pipeline_config_idx);
   ```

   So a PBR material with variant 3 drawn in the AAA opaque pass with no shadow casters asks for `pbr_var-3_pipe-forward-cfg-5.vsb` and `.fsb`; with both shadow slots lit it would be `cfg-8`.

2. Sets the material's uniform values, then any program defaults the material did not override (`:2047-2054`).
3. Binds the material's textures, then any program default textures not overridden (`:2059-2071`).
4. Calls `DrawDisplayList`, which sets the pipeline-wide uniforms (lights, fog, shadow matrices), the index and vertex buffers, the material's render state bits, and submits (`:1910-1919`).

Inside the loop, Harfang remembers the last transform index and the cache slot `bgfx::setTransform` returned for it; when the next display list belongs to the same node it reuses that slot instead of uploading the matrix again (`:2111`, `:2119-2125`; bgfx documents the returned cache index at `bgfx.h:3573-3578`).

---

## The Shader Permutation Scheme, Without the Shaders

A "pipeline program" on disk is a small JSON file listing optional features, for example `OptionalBaseColorOpacityMap`, `OptionalNormalMap`, `OptionalSkinning`, `OptionalAlphaCut` (the 16 recognized names are at `render_pipeline.cpp:697-728`; the enum at `render_pipeline.h:129-152`). Each feature has two states, so a program with N features has 2^N variants (`render_pipeline.cpp:857-864`). The variant index is the feature states read as a little-endian binary number (`:866-876`).

A material does not choose its variant. It is derived: `GetMaterialPipelineProgramFeatureStates` sets the bit for `OptionalNormalMap` if and only if the material has a texture named `uNormalMap`, and so on for every optional map; the flag-type features read material flags (`:892-939`). Attaching a texture changes the shader. `UpdateMaterialPipelineProgramVariant` recomputes the index (`:1017-1023`).

The asset compiler does the multiplication ahead of time. For each pipeline program it enumerates every feature-state combination (`tools/assetc/assetc.cpp:1352-1368`), and for each of those it compiles once per pipeline configuration with that configuration's defines appended (`:1338-1348`), naming the output exactly as the runtime will ask for it (`:1439-1441`). A program with five optional features becomes 32 x 10 = 320 compiled vertex-and-fragment pairs. The runtime loads only the ones a frame actually needs, and logs each one (`render_pipeline.cpp:2022`).

The ten configurations and their defines, which are the only view into what the shaders do:

| Index | Defines | Used by |
|-------|---------|---------|
| 0 | `FORWARD_PIPELINE_AAA_PREPASS`, `FORWARD_PIPELINE_AAA`, `FORWARD_PIPELINE` | AAA attribute prepass |
| 1 to 4 | `FORWARD_PIPELINE` plus none, `SLOT0_SHADOWS`, `SLOT1_SHADOWS`, or both | Basic opaque and transparent; AAA transparent |
| 5 to 8 | `FORWARD_PIPELINE_AAA`, `FORWARD_PIPELINE` plus the same shadow combinations | AAA opaque |
| 9 | `DEPTH_ONLY` | Shadow cascades, spot shadow |

(`forward_pipeline.cpp:395-416`; the index arithmetic at `scene_forward_pipeline.cpp:501-522` is `1 + shadow_bits` for basic and `5 + shadow_bits` for AAA.)

Compare this with Filament, which compiles one material definition into per-backend shaders at build time through `matc`, and with three.js, which assembles shader strings at runtime from material properties. Harfang sits between them: ahead-of-time like Filament, but with the permutation space enumerated by brute force rather than by analyzing the material, and with the material-to-permutation mapping done at runtime by texture name.

---

## The AAA Path: The Same Scene Through a Longer Chain of Buckets

The AAA overload of `SubmitSceneToForwardPipeline` (`scene_forward_pipeline.cpp:602-877`) reuses stages 1 to 6 unchanged and replaces stages 7 and 8 with a longer chain. The `ForwardPipelineAAA` struct is the set of render targets that chain writes (`scene_forward_pipeline.h:61-148`, allocated at `.cpp:147-288`):

| Target | Format | Holds |
|--------|--------|-------|
| `attributes_fb` | D24 + two RGBA16F | Depth; `attr0` = view normal in xyz, linear depth in w; `attr1` = velocity in yz (`.cpp:157-162`) |
| `work[0]`, `work[1]` | RGBA16F at the SSGI and SSR ratios | Scratch for the screen-space passes (`.cpp:168-178`) |
| `ssgi_history[2]`, `ssr_history[2]` | RGBA16F at ratio | Ping-pong temporal history, indexed by `frame & 1` (`.cpp:192-196`, `:211-216`, `:674-675`) |
| `frame_hdr_fb` | RGBA16F sharing the attribute depth | The lit frame (`.cpp:226-231`) |
| `prv_frame_hdr_fb`, `next_frame_hdr_fb` | RGBA16F | Last frame and this frame after TAA; swapped by `Flip` (`.cpp:235-237`, `:36-39`) |
| `noise[64]` | Loaded PNGs | Blue noise, one per frame (`.h:62`, `.cpp:153-154`, `:654`) |

The chain, in ticket order (line numbers are `scene_forward_pipeline.cpp`):

```
 view_id →  Attribute prepass (cfg 0, opaque + skinned, previous matrices → velocity)   :631-651
         →  Downsample color/normals/depth to half (if either ratio is Half)             :658-662
         →  HiZ depth pyramid                                                             :664-672
         →  SSGI  → temporal accumulate → blur → upsample                                 :680-705
         →  SSR   → temporal accumulate → upsample                                        :707-727
         →  bind SSGI/SSR results as uSSIrradianceMap / uSSRadianceMap                    :740
         →  Opaque pass into frame_hdr_fb (cfg 5-8, jittered projection)                  :742-768
         →  Transparent pass into frame_hdr_fb (cfg 1-4, basic lighting)                  :773-796
         →  TAA  (frame_hdr + prv_frame_hdr → next_frame_hdr)                             :799-800
         →  Motion blur (next → work_frame_hdr)                                           :803-804
         →  Bloom (always), then DOF only if dof_focus_length != 0                        :807-816
         →  Compositing quad: exposure and gamma, or a plain copy                          :818-876
```

Each `Compute*` and `Apply*` call lives in its own module with a `Create`/`Apply`/`Destroy` triple, a handful of sampler uniforms and one program; `engine/taa.h` is representative at 35 lines. Every one of them takes at least one ticket. TAA takes exactly one (`taa.cpp:68`).

Three details change how you read the result:

- **The projection is jittered.** `TAAHaltonJitter8(frame)` is scaled to pixels and added to the projection matrix's third column (`:625-629`), and the unjittered view-projection is also uploaded (`forward_pipeline.cpp:188`) so TAA can reproject.
- **Transparent objects do not get the AAA lighting.** The transparent pass selects a basic configuration (`:784`), so glass and particles see neither the screen-space GI nor the reflections that the opaque pass just computed.
- **SAO is wired out.** A `SAO` member and its stage exist under `#if 0` (`scene_forward_pipeline.h:78-85`, `.cpp:729-737`). The `sao.cpp` module is real and bound to Python (`bind_harfang.py:4354`), but the AAA chain does not call it at this commit.

The only switch between the tiers is which `SubmitSceneToPipeline` overload the host calls (`scene_forward_pipeline.h:225-242`). The scene, the materials, the display lists and the first six stages are identical. What the AAA path adds is targets, passes, and the choice of configuration index 5 to 8 instead of 1 to 4 for the opaque pass.

---

## Reading the Frame Back and Talking to the Backend

Two smaller mechanisms round out the pipeline.

**Capture.** `CaptureTexture` takes a view id, blits a render target into a texture created with `BGFX_TEXTURE_READ_BACK | BGFX_TEXTURE_BLIT_DST`, and returns the frame number at which `bgfx::readTexture` will have filled the picture (`render_pipeline.cpp:2319-2333`; bgfx documents the frame-number contract at `bgfx.h:2954`). The host compares that number against what `hg.Frame()` returns before saving the PNG. There is no synchronous screenshot. Two details: the function spends a ticket before blitting (`:2328`), and on wrong texture flags it returns `BGFX_INVALID_HANDLE`, a 16-bit sentinel of 65535, through the 32-bit frame-number return (`:2323-2326`), so a caller that does not check for it waits for frame 65535.

**Backend selection.** `RenderInit` builds a `bgfx::Init`, sets the native window handle from the platform layer, and calls `bgfx::init` (`render_pipeline.cpp:2648-2690`). Harfang's "let bgfx choose" sentinel is `RendererType::Noop`: when the caller passes it, `init.type` is left at bgfx's default, which is `RendererType::Count`, and bgfx picks a backend for the platform (`:2659-2662`; `bgfx.h:648-649`; `extern/bgfx/bgfx/src/bgfx.cpp:3439-3440`). Frame latency is clamped to one (`:2674`). After init, the engine reads two capability bits, `originBottomLeft` and `homogeneousDepth`, and feeds them to its projection code (`:2685-2686`), which is how the same shadow crop matrix works on OpenGL and Direct3D (`forward_pipeline.cpp:206-212`). The Emscripten build targets WebGL 2 with an OpenGL ES 3.0 minimum (`MAX_WEBGL_VERSION=2`, `USE_WEBGL2=1`, `BGFX_CONFIG_RENDERER_OPENGLES_MIN_VERSION=30` at `CMakeLists.txt:121`).

---

## Gotchas and Readings to Verify

Findings from reading the code. None was confirmed by running the engine.

- **The shadow-pass view ids never reach the caller.** The common preparation stores the spot id with the forward-pipeline enum, `FPSP_Slot1Spot` (value 4, `forward_pipeline.h:100`), into the scene-pass array where index 4 is a cascade slot (`scene_forward_pipeline.cpp:538`; the scene enum at `.h:165-175` puts the spot at 6). The view-dependent preparation then overwrites indices 2 to 5 with the cascades (`:550-553`), and both submit functions reset the whole array to 65535 before recording opaque and transparent (`:616`, `:889`). Whatever the intent, the five shadow entries a caller reads back are always 65535. Code reading, untested.
- **`fb_size` is built from `rb_width` twice** (`scene_forward_pipeline.cpp:607`). Only the custom render-buffer-size overload passes non-zero values, so the common path is unaffected.
- **Skinned meshes are never frustum-culled** and their transparent sort keys are all zero (`:560-562`, `:493-496`; `forward_pipeline.cpp:337`, `:386`).
- **The spot shadow pass runs whenever slot 1 holds a light**, shadows or not (`forward_pipeline.cpp:358-363`); and a point light with shadows enabled takes that path with a zero field of view (`scene_forward_pipeline.cpp:416-428`).
- **Transparent objects behind the near plane share one sort key** because the clamp precedes the 100 metre offset (`scene_forward_pipeline.cpp:476-477`, `render_pipeline.cpp:89-94`).
- **`CaptureTexture` reports its error as frame 65535** (`render_pipeline.cpp:2323-2326`).
- **Three bone-count constants are hand-synced**: `max_skinned_model_matrix_count` is 32 (`render_pipeline.h:38`), bgfx's `BGFX_CONFIG_MAX_BONES` is 32 (`bgfx_shader.sh:9-11`), and the `uPreviousModel` uniform is created with 96 matrices and a comment to keep it in sync (`render_pipeline.cpp:2683`).
- **Bloom is not optional** in the AAA path (`:807`, marked `TODO`).
- **Opaque draws carry depth 0**, so there is no front-to-back ordering for early-z; bgfx groups them by program.
- **`program_shaders` is a global map that grows for every loaded program and is never pruned** (`render_pipeline.cpp:570`, `:616`), kept for uniform introspection in the editor.
- **The model file embeds a raw `bgfx::VertexLayout` struct** (`render_pipeline.cpp:1720-1721`). The `.geo` format is therefore tied to the memory layout of a bgfx type at the version Harfang vendors.
- **Shadow constants are hard-coded**: the cascade backup distance is 200 metres (`forward_pipeline.cpp:290`), the spot shadow frustum is 0.1 to 100 metres (`:365`).

---

## What Flux Should Take From This

| Pattern | Verdict | Why |
|---------|---------|-----|
| View id as a counter threaded by reference, with a per-pass id table returned | Adopt the shape | It is the simplest possible render-graph: passes compose by consuming ids, and callers can still target a named pass. Flux's equivalent is a pass handle allocator, but the "return which ids each pass got" idea is worth keeping |
| Material variant derived from texture presence | Adopt with a guard | Removes a whole category of user error (forgetting to enable a feature after attaching a map). Flux should make the derivation explicit in the material type so it is not a string lookup on `uNormalMap` |
| Variant x configuration precompiled by brute force | Modify | Works at 2^5 x 10. At 2^10 it does not. Flux should enumerate only the permutations the content actually uses, which is what the on-demand loading already hints at |
| Two tiers over one scene by choosing a configuration range | Adopt | The clean part of the design: the scene never knows the tier. Flux's quality tiers should be a property of the submit call, not of the scene |
| Transparent objects on the basic configuration in the AAA tier | Avoid | A silent quality cliff. If Flux has tiers, every pass should be on the same one or the mismatch should be an explicit setting |
| Eight fixed light slots, two shadow casters | Modify | Fine for an embedded dashboard; Flux targets installations with many lights. Clustered or tiled lighting changes this, but the "sort by priority and drop the rest" fallback is still the right degradation |
| Asynchronous read-back that returns a frame number | Adopt | The honest API for GPU read-back. wgpu's `map_async` is the same contract |

---

## Next Steps

- A full `code-traces/scene-to-pixels.md` would read the shader sources alongside this. That needs Harfang's shader package fetched into `references/harfang3d/`, since the checkout has none.
- The [architecture document](./architecture.md) covers the scene, handles and resource tables this pipeline consumes.
- For the opposite backend strategy, compile-time selection with one binary per API, see the [fr_public graphics abstraction trace](../../per-demoscene/fr_public/code-traces/graphics-abstraction.md).
- For the other ahead-of-time material compiler in this repository, see [Filament](../../per-library/cpp/filament/README.md).
