# Code Trace: Scene Graph to GPU Draw Calls

> Tracing how Phoenix engine transforms a hierarchical scene graph into GPU draw calls in the apEx demotool.

Every frame in a 64k intro, a timeline event fires and the scene needs to render. But there's a fascinating journey between "render this scene" and actual pixels on screen. The Phoenix engine doesn't just traverse a scene graph and call draw. Instead, it performs a complete transformation: evaluating spline animations at precise timestamps, accumulating transformation matrices through parent-child hierarchies, expanding materials into multiple render passes, and finally sorting everything by priority before issuing draw calls.

This matters because most creative coding frameworks hide this complexity behind high-level APIs. But when you're building a demo that needs to fit in 64 kilobytes, every design choice is deliberate. No instancing. No batching. One render instance equals one draw call. The approach is surprisingly direct, yet reveals important patterns about when to prioritize simplicity over optimization.

Understanding this flow illuminates three critical design decisions: why material expansion happens during scene traversal instead of at render time, why render layers enable sophisticated multi-pass effects without complicated state management, and why the complete absence of frustum culling makes sense when every object in your scene is carefully authored to be visible.

The problem Phoenix solves is this: given a scene graph with animated objects, materials with multiple rendering passes, and render layers for effects like bloom or depth-of-field, how do you generate the minimal set of GPU commands to produce the desired output? The engine needs to respect parent-child transformation hierarchies, evaluate per-frame spline data, handle materials that expand into multiple draw calls, and ensure render priority ordering all happens correctly.

## The Mental Model: Material Expansion

Think of scene rendering like a cookbook where some recipes have sub-recipes. You start with a scene graph containing mesh objects. Each mesh has a material. But materials aren't simple, they're techniques with multiple passes. A single "chrome metal" material might have three passes: base color, environment reflection, and specular highlight.

When Phoenix traverses the scene graph, it doesn't create one render command per object. Instead, it expands each object-material pair into multiple render instances, one per material pass. It's like taking that cookbook recipe and generating a separate instruction card for each sub-step, complete with all the ingredients and tools needed. Each card is self-contained, ready to execute independently.

This expansion happens early, during scene graph traversal, not later during rendering. By the time the renderer iterates through instances, every decision has been made. Every GPU handle, every matrix, every shader parameter is baked into a flat structure. The render loop becomes trivial: iterate the list, bind state, draw.

## Entry Point: Timeline Event Trigger

**File**: `apEx/Phoenix/Timeline.cpp:152`

The journey begins when a timeline event fires. In a demo, the timeline controls everything: camera movements, scene transitions, post-processing effects. When it's time to render a scene, the timeline calls the render scene event.

```cpp
void CphxEvent_RenderScene::Render(float t, float prevt, float aspect, bool subroutine)
{
  if (!Scene || (!Camera && !cameraOverride)) return;

  CphxObject* actualCamera = cameraOverride ? cameraOverride : Camera;

  // Calculate view and projection matrices (motion blur needs prev frame)
  for (int x = 0; x < 2; x++)
  {
    phxPrevFrameViewMatrix = phxViewMatrix;
    phxPrevFrameProjectionMatrix = phxProjectionMatrix;

    Scene->UpdateSceneGraph(Clip, x ? t : prevt);
    // ... camera setup ...
  }

  Scene->Render(ClearColor, ClearZ);
}
```

Notice the loop runs twice: once for the current time `t`, once for the previous time `prevt`. This isn't redundant. Motion blur effects need to know where objects were last frame and where they are now. The scene graph updates twice, building two complete sets of transformation data, but only the second pass generates visible output.

The aspect ratio comes from the render target resolution. The `subroutine` flag indicates whether this is a nested render-to-texture operation. But the core flow is simple: update the scene graph with animation data, set up camera matrices, then render.

## Scene Graph Update: Clearing and Traversal

**File**: `apEx/Phoenix/Scene.cpp:51`

Scene graph update is where the real work begins. The engine clears all render queues, then walks the hierarchy depth-first, building transformation matrices and collecting render data.

```cpp
void CphxScene::UpdateSceneGraph(int Clip, float t)
{
  D3DXMATRIX Root;
  D3DXMatrixIdentity(&Root);

  // Clear all render layer queues
  for (int x = 0; x < LayerCount; x++)
    RenderLayers[x]->RenderInstances.FreeArray();

  LightCount = 0;
  UpdateSceneGraph(Clip, t, Root, this, NULL);

  // Calculate target directions for spotlights
  for (int x = 0; x < ObjectCount; x++)
  {
    CphxObject *o = Objects[x];
    if (o->Target)
    {
      o->TargetDirection = o->Target->WorldPosition - o->WorldPosition;
      D3DXVec3Normalize(&o->TargetDirection, &o->TargetDirection);
      // Store in spline results for shader access
      o->SplineResults[Spot_Direction_X] = o->TargetDirection.x;
      o->SplineResults[Spot_Direction_Y] = o->TargetDirection.y;
      o->SplineResults[Spot_Direction_Z] = o->TargetDirection.z;
    }
  }

  CollectLights(this);

  // Sort each layer by render priority
  for (int x = 0; x < LayerCount; x++)
    SortRenderLayer(RenderLayers[x]->RenderInstances.Array, 0,
                    RenderLayers[x]->RenderInstances.ItemCount - 1);
}
```

This function establishes the pattern: clear, traverse, post-process, sort. The identity matrix serves as the root transformation. Every child in the hierarchy will multiply its local transform against this accumulated parent matrix.

The light collection happens after traversal because object world positions aren't known until transformation matrices are computed. Sorting by render priority ensures transparent objects render after opaque ones, and that sky domes draw before everything else.

## Hierarchy Traversal: Animation and Transformation

**File**: `apEx/Phoenix/Scene.cpp:229`

Each object in the scene graph traverses recursively. This is where spline animation data gets evaluated and transformation matrices accumulate down the hierarchy.

```cpp
void CphxObject::TraverseSceneGraph(int Clip, float t, D3DXMATRIX CurrentMatrix,
                                     CphxScene *RootScene, void *SubSceneData)
{
  D3DXMATRIX m = CurrentMatrix;
  CalculateAnimation(Clip, t);  // Evaluate all splines at time t

  // Build position-rotation-scale matrix from spline results
  D3DXMATRIX prs;
  D3DXMatrixTransformation(&prs, NULL, NULL,
                           (D3DXVECTOR3*)&SplineResults[Spline_Scale_x],
                           NULL,
                           &RotationResult,
                           (D3DXVECTOR3*)&SplineResults[Spline_Position_x]);

  // Multiply local transform by parent transform
  D3DXMatrixMultiply(&m, &prs, &CurrentMatrix);

  prevMatrix = currMatrix;
  currMatrix = m;

  // Calculate world position
  D3DXVECTOR4 v;
  D3DXVec3Transform(&v, (D3DXVECTOR3*)&SplineResults[Spline_Position_x], &CurrentMatrix);
  WorldPosition = *(D3DXVECTOR3*)&v;

  // Polymorphic dispatch: mesh objects create render instances
  CreateRenderDataInstances(Clip, m, RootScene, SubSceneData ? SubSceneData : ToolData);

  // Recurse to children with accumulated matrix
  for (int x = 0; x < ChildCount; x++)
    Children[x]->TraverseSceneGraph(Clip, t, m, RootScene, SubSceneData);
}
```

This is the heart of the scene graph. The `CalculateAnimation` call evaluates every spline curve at the current timestamp. Position, rotation, scale, color, material parameters all come from splines. In the demoscene, everything is animated.

The accumulated matrix `m` flows down the hierarchy. A hand attached to an arm attached to a shoulder: each local transformation multiplies against the parent's world transformation. By the time we reach a leaf mesh, `m` contains the complete world transformation from root to leaf.

The `CreateRenderDataInstances` call is polymorphic. For mesh objects, it triggers material expansion. For lights, it does nothing. For particle emitters, it updates particle simulation. This is where the path splits based on object type.

## Model Processing: Matrix Calculation and Material Data

**File**: `apEx/Phoenix/Model.cpp:25`

When a mesh object creates render instances, it calculates final transformation matrices and applies animated material parameters.

```cpp
void CphxModelObject_Mesh::CreateRenderDataInstances(CphxObjectClip *Clip,
                                                       const D3DXMATRIX &m,
                                                       CphxScene *RootScene,
                                                       void *CloneData)
{
  if (!Material) return;

  // World matrix and inverse-transpose for normal transformation
  D3DXMatrixMultiply(&phxWorldMatrix, &GetMatrix(), &m);
  D3DXMatrixInverse(&phxITWorldMatrix, NULL, &phxWorldMatrix);
  D3DXMatrixTranspose(&phxITWorldMatrix, &phxITWorldMatrix);

  // Apply animated material splines
  Clip->MaterialSplines->ApplyToParameters(this);

  // Collect animated data for each material pass
  int passid = 0;
  for (int x = 0; x < Material->TechCount; x++)
    for (int y = 0; y < Material->Techniques[x]->PassCount; y++)
      Material->Techniques[x]->CollectAnimatedData(MaterialState[passid++], y);

  // Create render instances (material expansion happens here)
  Material->CreateRenderDataInstances(this, RootScene, CloneData ? CloneData : ToolObject);
}
```

The `GetMatrix()` call retrieves the object's local transform. Multiplying against the parent matrix `m` produces the final world matrix. The inverse-transpose matrix is crucial for transforming normal vectors correctly, preserving their perpendicularity to surfaces even under non-uniform scaling.

Material splines are separate from object splines. An object might animate position while its material animates color or shininess. Both sets of splines evaluate at the same timestamp, producing synchronized motion and appearance changes.

The loop collects animated data for each pass. If a material has two techniques and the first has two passes while the second has three, this generates five separate material states. Each state contains constant data (set once when the material is created) plus animated data (evaluated every frame from splines).

## Material Expansion: One Instance Per Pass

**File**: `apEx/Phoenix/Material.cpp:117`

Material expansion is where one mesh becomes multiple render instances. Each material pass generates a separate instance with complete GPU state.

```cpp
void CphxMaterialTechnique::CreateRenderDataInstances(
  CphxMaterialPassConstantState **MaterialState, int &passid,
  CphxScene *RootScene, ID3D11Buffer *VertexBuffer, ID3D11Buffer *IndexBuffer,
  ID3D11Buffer *WireBuffer, int VertexCount, int IndexCount,
  void *ToolData, bool Indexed)
{
  for (int x = 0; x < PassCount; x++)
  {
    CphxRenderDataInstance *ri = new CphxRenderDataInstance();

    // Geometry buffers
    ri->VertexBuffer = VertexBuffer;
    ri->IndexBuffer = IndexBuffer;
    ri->WireBuffer = WireBuffer;
    ri->TriIndexCount = VertexCount;
    ri->WireIndexCount = IndexCount;
    ri->Indexed = Indexed;

    // Render state from animated material
    ri->Wireframe = MaterialState[passid]->Wireframe;
    ri->RenderPriority = MaterialState[passid]->RenderPriority;

    // Shader stages (copy 5 pointers: VS, PS, GS, HS, DS)
    memcpy(&ri->VS, &RenderPasses[x]->VS, sizeof(void*) * 5);

    // Blend, rasterizer, depth-stencil states and textures
    memcpy(&ri->BlendState, &MaterialState[passid]->BlendState, sizeof(void*) * 11);

    // Material constant and animated data
    int constdatasize = MaterialState[passid]->ConstantDataSize;
    int dyndatasize = MaterialState[passid]->AnimatedDataSize;
    memcpy(ri->MaterialData, MaterialState[passid]->ConstantData, constdatasize);
    memcpy(ri->MaterialData + constdatasize/sizeof(float),
           MaterialState[passid]->AnimatedData, dyndatasize);

    // Transformation matrices
    ri->Matrices[0] = phxWorldMatrix;
    ri->Matrices[1] = phxITWorldMatrix;

    // Add to render queue
    RootScene->AddRenderDataInstance(TargetLayer, ri);

    passid++;
  }
}
```

Here's where the cookbook analogy becomes concrete. Each pass creates a completely independent render instance. The instance holds everything needed to issue a draw call: vertex buffer, index buffer, shader handles, blend state, rasterizer state, depth-stencil state, eight texture slots, two transformation matrices, and a block of material parameter data.

The `memcpy` calls are optimization. Instead of copying fields individually, the code copies contiguous blocks. The comment warns against reordering struct members because this relies on memory layout.

Crucially, this happens during scene traversal, not during rendering. By the time the render loop starts, all decisions are made. The render loop just executes pre-computed commands.

## Queue Addition: Layer Organization

**File**: `apEx/Phoenix/Scene.cpp:205`

Each render instance gets added to a specific render layer. Layers are how Phoenix implements multi-pass rendering effects.

```cpp
void CphxScene::AddRenderDataInstance(CphxRenderLayerDescriptor *Layer,
                                       CphxRenderDataInstance *RDI)
{
  for (int x = 0; x < LayerCount; x++)
    if (RenderLayers[x]->Descriptor == Layer)
    {
      RenderLayers[x]->RenderInstances.Add(RDI);
      return;
    }

  #ifndef PHX_MINIMAL_BUILD
  delete RDI;  // Layer not found, clean up
  #endif
}
```

Render layers enable effects like this: Layer 0 renders the scene to a texture. Layer 1 applies bloom to that texture. Layer 2 combines the bloomed result with a depth-of-field blur. Layer 3 applies color grading and outputs to the screen.

Each layer can target different render textures, clear buffers differently, and render at different resolutions. A motion blur effect might render the scene at half resolution to a velocity buffer in one layer, then use that buffer in a later layer to blur the final image.

The layer descriptor is set in the material definition. When artists create materials, they specify which layer each technique targets. This decouples material design from effect implementation.

## Render Execution: Iterating Layers and Instances

**File**: `apEx/Phoenix/Scene.cpp:136`

After scene graph traversal completes, the render function processes each layer in order, uploading scene-level data and rendering all instances.

```cpp
void CphxScene::Render(bool ClearColor, bool ClearZ, int cubeResolution)
{
  SetSamplers();

  // Calculate inverse matrices for unprojection
  D3DXMatrixInverse(&phxIViewMatrix, NULL, &phxViewMatrix);
  D3DXMatrixInverse(&phxIProjectionMatrix, NULL, &phxProjectionMatrix);

  for (int x = 0; x < LayerCount; x++)
  {
    RenderLayers[x]->Descriptor->SetEnvironment(ClearColor, ClearZ, cubeResolution);

    // Upload scene constant buffer
    D3D11_MAPPED_SUBRESOURCE map;
    phxContext->Map(SceneDataBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
    unsigned char* m = (unsigned char*)map.pData;

    memcpy(m, &phxViewMatrix, sizeof(phxViewMatrix)); m += sizeof(phxViewMatrix);
    memcpy(m, &phxProjectionMatrix, sizeof(phxProjectionMatrix)); m += sizeof(phxProjectionMatrix);
    memcpy(m, &phxCameraPos, sizeof(phxCameraPos)); m += sizeof(phxCameraPos);

    float LightCountData[4] = { (float)LightCount };
    memcpy(m, &LightCountData, sizeof(LightCountData)); m += sizeof(LightCountData);
    memcpy(m, Lights, sizeof(LIGHTDATA) * MAX_LIGHT_COUNT); m += sizeof(LIGHTDATA) * MAX_LIGHT_COUNT;

    float RTResolution[4];
    if (RenderLayers[x]->Descriptor->TargetCount)
    {
      RTResolution[0] = (float)RenderLayers[x]->Descriptor->Targets[0]->XRes;
      RTResolution[1] = (float)RenderLayers[x]->Descriptor->Targets[0]->YRes;
      RTResolution[2] = 1 / RTResolution[0];  // Reciprocals for shader use
      RTResolution[3] = 1 / RTResolution[1];
    }
    memcpy(m, RTResolution, 16); m += 16;

    memcpy(m, &phxIViewMatrix, sizeof(phxIViewMatrix)); m += sizeof(phxIViewMatrix);
    memcpy(m, &phxIProjectionMatrix, sizeof(phxIProjectionMatrix)); m += sizeof(phxIProjectionMatrix);

    phxContext->Unmap(SceneDataBuffer, 0);

    // Bind scene data to all shader stages
    phxContext->VSSetConstantBuffers(0, 1, &SceneDataBuffer);
    phxContext->GSSetConstantBuffers(0, 1, &SceneDataBuffer);
    phxContext->PSSetConstantBuffers(0, 1, &SceneDataBuffer);

    // Render all instances in this layer
    for (int y = 0; y < RenderLayers[x]->RenderInstances.NumItems(); y++)
      RenderLayers[x]->RenderInstances[y]->Render();

    RenderLayers[x]->Descriptor->GenMipmaps();
  }
}
```

The scene constant buffer contains shared data: view matrix, projection matrix, camera position, light count and light data, render target resolution and reciprocals, plus inverse matrices. Every shader can access this without per-instance uploads.

The render target resolution reciprocals are a micro-optimization. Instead of dividing by resolution in shaders, multiply by the reciprocal. On older GPUs, reciprocals were slower than multiplication. Modern GPUs often optimize this automatically, but the pattern persists.

Notice how constant buffer slot 0 gets the scene data, while slot 1 will receive object matrices during instance rendering. This two-tier structure separates shared data from per-instance data.

After all instances render, the layer descriptor generates mipmaps if needed. Render-to-texture effects often need mipmap chains for blurring or level-of-detail sampling.

## Draw Call Execution: Binding State and Drawing

**File**: `apEx/Phoenix/RenderLayer.cpp:27`

The final step is rendering a single instance. This function binds all GPU state and issues the draw call.

```cpp
void CphxRenderDataInstance::Render()
{
  if (!VS || !PS) return;  // Invalid state, skip
  if (!VertexBuffer) return;

  unsigned int offset = 0;
  unsigned int stride = PHXVERTEXFORMATSIZE;

  // Set vertex format and buffers
  phxContext->IASetInputLayout(RenderVertexFormat);
  phxContext->IASetVertexBuffers(0, 1, &VertexBuffer, &stride, &offset);
  phxContext->IASetPrimitiveTopology(Wireframe ?
    D3D11_PRIMITIVE_TOPOLOGY_LINELIST : D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

  // Bind shader stages
  phxContext->VSSetShader(VS, NULL, 0);
  phxContext->GSSetShader(GS, NULL, 0);
  phxContext->HSSetShader(HS, NULL, 0);
  phxContext->DSSetShader(DS, NULL, 0);
  phxContext->PSSetShader(PS, NULL, 0);

  // Bind render states
  phxContext->RSSetState(RasterizerState);
  phxContext->OMSetBlendState(BlendState, NULL, 0xffffffff);
  phxContext->OMSetDepthStencilState(DepthStencilState, 0);

  // Upload object constant buffer (matrices + material data)
  D3D11_MAPPED_SUBRESOURCE map;
  phxContext->Map(ObjectMatrixBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
  memcpy(map.pData, Matrices, 16 * 2 * 4);  // Two 4x4 matrices
  memcpy(((unsigned char*)map.pData) + sizeof(Matrices),
         MaterialData, MATERIALDATASIZE);
  phxContext->Unmap(ObjectMatrixBuffer, 0);

  // Bind textures to all stages
  phxContext->VSSetShaderResources(0, 8, Textures);
  phxContext->GSSetShaderResources(0, 8, Textures);
  phxContext->PSSetShaderResources(0, 8, Textures);

  // Bind index buffer and draw
  phxContext->IASetIndexBuffer(Wireframe ? WireBuffer : IndexBuffer,
                               DXGI_FORMAT_R32_UINT, 0);

  if (Wireframe ? WireIndexCount : TriIndexCount)
    phxContext->DrawIndexed(Wireframe ? WireIndexCount : TriIndexCount, 0, 0);
}
```

This is where all the preparation pays off. The render loop is simple: bind vertex format, bind vertex buffer, set topology, bind five shader stages, bind three render states, upload object data, bind eight textures, bind index buffer, draw.

The `D3D11_MAP_WRITE_DISCARD` flag tells DirectX to allocate new memory instead of waiting for the GPU to finish using the old buffer. This avoids stalls. Every frame gets fresh memory for constant buffers.

Texture binding happens to all shader stages simultaneously. Even though most shaders only use textures in the pixel shader, vertex shaders might sample displacement maps and geometry shaders might sample noise textures. Binding to all stages is simpler than tracking which stages actually need which textures.

The wireframe mode uses a different index buffer. Procedural mesh generators create both a triangle index buffer and a wireframe index buffer. The wireframe buffer contains line indices suitable for debug visualization.

## Data Flow Summary

The complete flow, from timeline event to pixels:

```
Timeline Event (t = 1.523 seconds)
    │
    ├─ Calculate camera view/projection matrices
    │
    ▼
UpdateSceneGraph (clear all render queues)
    │
    ├─ For each root object
    │     │
    │     ▼
    │  TraverseSceneGraph (depth-first)
    │     │
    │     ├─ Evaluate splines at time t
    │     ├─ Build transformation matrix
    │     ├─ Accumulate with parent matrix
    │     │
    │     ▼
    │  CreateRenderDataInstances (polymorphic)
    │     │
    │     ├─ Calculate world matrix
    │     ├─ Calculate inverse-transpose matrix
    │     ├─ Apply material splines
    │     ├─ Collect animated material data
    │     │
    │     ▼
    │  Material->CreateRenderDataInstances
    │     │
    │     ├─ For each material pass
    │     │    │
    │     │    ├─ Allocate CphxRenderDataInstance
    │     │    ├─ Copy all GPU handles and states
    │     │    ├─ Copy matrices and material data
    │     │    │
    │     │    ▼
    │     └─ AddRenderDataInstance (to layer queue)
    │
    ├─ Calculate spotlight target directions
    ├─ Collect lights (up to 8)
    └─ Sort each layer by render priority

Render (for each layer)
    │
    ├─ SetEnvironment (bind render targets)
    ├─ Upload scene constant buffer
    │     (view/projection matrices, lights, camera pos)
    │
    ├─ For each render instance in layer
    │     │
    │     ▼
    │  RenderDataInstance->Render()
    │     │
    │     ├─ Bind vertex buffer and format
    │     ├─ Bind 5 shader stages
    │     ├─ Bind 3 render states
    │     ├─ Upload object constant buffer
    │     │     (world matrix, inverse-transpose, material data)
    │     ├─ Bind 8 textures
    │     ├─ Bind index buffer
    │     │
    │     ▼
    │  phxContext->DrawIndexed()
    │
    └─ GenerateMipmaps (if layer needs them)

Pixels on Screen
```

## Key Data Structures

Understanding the data structures helps illuminate the design:

**CphxRenderDataInstance** (RenderLayer.h:10)
```cpp
class CphxRenderDataInstance
{
  int RenderPriority;           // Sort key
  bool Wireframe;               // Debug mode
  bool Indexed;                 // Triangle list vs point list

  ID3D11Buffer *VertexBuffer;   // Geometry
  ID3D11Buffer *IndexBuffer;
  ID3D11Buffer *WireBuffer;     // Debug wireframe indices

  ID3D11VertexShader *VS;       // All shader stages
  ID3D11PixelShader *PS;
  ID3D11GeometryShader *GS;
  ID3D11HullShader *HS;
  ID3D11DomainShader *DS;

  ID3D11BlendState *BlendState;           // Pipeline states
  ID3D11RasterizerState *RasterizerState;
  ID3D11DepthStencilState *DepthStencilState;
  ID3D11ShaderResourceView *Textures[8];

  D3DXMATRIX Matrices[2];      // World, inverse-transpose
  float MaterialData[...];      // Flattened material parameters

  void *ToolData;               // Editor metadata

  void Render();
};
```

This structure contains every piece of state needed to issue a draw call. No lookups, no indirection. It's completely self-contained.

**Scene Hierarchy**

The scene graph is a simple parent-child hierarchy:

```
CphxScene
├─ Objects[]
│  ├─ CphxObject (base class)
│  │  ├─ Parent pointer
│  │  ├─ Children[]
│  │  ├─ SplineResults[] (evaluated animation data)
│  │  └─ virtual CreateRenderDataInstances()
│  │
│  ├─ CphxModelObject_Mesh : CphxObject
│  │  ├─ Material pointer
│  │  └─ CreateRenderDataInstances() override
│  │
│  └─ CphxObject_Light : CphxObject
│     └─ CreateRenderDataInstances() override (does nothing)
│
└─ RenderLayers[]
   ├─ CphxRenderLayer
   │  ├─ Descriptor (target textures, clear flags)
   │  └─ RenderInstances[] (sorted by priority)
   │
   └─ ...
```

Objects hold animation state. Materials hold rendering state. Layers hold instance queues. Clean separation of concerns.

## Key Observations

**1. Material Expansion Creates One Instance Per Pass**

This is the most surprising aspect. A scene with 100 meshes and materials averaging 2 passes generates 200 render instances and 200 draw calls. No batching. No instancing. For a 64k intro with carefully authored content, this is acceptable. Every object is visible, every pass is necessary.

A general-purpose engine would batch instances with identical materials, use instancing for repeated geometry, or merge static geometry into uber-meshes. But those techniques add code size. Phoenix prioritizes simplicity.

**2. Early Decision Making**

By the time rendering starts, every decision is made. Shader selection, blend mode, material parameters, transformation matrices all freeze during scene traversal. The render loop has zero conditional logic. It just iterates and binds.

This pattern trades memory for CPU time. Storing complete GPU state for every instance uses more memory than storing indices into shared state objects. But it eliminates hash table lookups, state diffing, and redundant bindings.

**3. No Frustum Culling**

The scene graph traversal visits every object, always. No bounding volume tests. No octree queries. This seems wasteful until you remember the content is tightly authored. In a demo, objects outside the view frustum are rare. The cost of culling checks exceeds the cost of rendering a few extra objects.

This wouldn't work for open-world games with thousands of objects spread across kilometers. But for a demo where every frame is choreographed, it's the right choice.

**4. Spline Animation Everywhere**

Position, rotation, scale, color, material parameters, everything animates via splines. The `CalculateAnimation` call evaluates potentially hundreds of spline curves every frame. This is expensive, but demos are all about motion. Static content doesn't justify making a demo.

Spline data is compact. Instead of keyframe arrays, splines store a few control points and interpolation modes. This compresses well in the final executable.

**5. Render Layers Enable Effect Composition**

Layers solve the multi-pass rendering problem elegantly. Each layer has independent render targets, clear flags, and instance queues. Effects compose naturally: render scene to texture (layer 0), blur it (layer 1), combine with original (layer 2).

Material definitions specify target layers. Artists don't write render pass orchestration code. They just tag materials with layer indices. The engine handles the rest.

**6. Sorting by Priority**

Render priority ensures correct draw order without manual management. Transparent objects get high priority values so they draw last. Sky domes get low priority to draw first. The sorting happens once per frame after scene traversal.

QuickSort on a small array is fast. Even with 200 instances, sorting takes microseconds. The memory access pattern during rendering benefits from sorted order because state changes cluster together.

## Implications for Rust Framework

This code trace reveals several patterns worth adopting and a few to avoid or modify.

### Adopt: Render Layers for Effect Composition

The layer system is elegant. Instead of manually orchestrating render passes, materials declare their target layer and the engine handles sequencing. This maps naturally to Rust:

```rust
struct RenderLayer {
    descriptor: LayerDescriptor,
    instances: Vec<RenderInstance>,
}

impl RenderLayer {
    fn add_instance(&mut self, instance: RenderInstance) {
        self.instances.push(instance);
    }

    fn render(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) {
        self.descriptor.bind_targets(device);
        for instance in &self.instances {
            instance.render(device, queue);
        }
        self.descriptor.generate_mipmaps(queue);
    }
}
```

Layers encapsulate render-to-texture operations cleanly. Post-processing effects, shadow maps, and reflection probes all use the same mechanism.

### Adopt: Spline Animation as First-Class Feature

Everything in Phoenix animates. The Rust framework should make spline animation trivial:

```rust
pub struct Spline<T> {
    control_points: Vec<(f32, T)>,
    interpolation: InterpolationMode,
}

impl<T: Interpolate> Spline<T> {
    pub fn evaluate(&self, t: f32) -> T {
        // Catmull-Rom, Bezier, or linear interpolation
    }
}

// Embed in objects
pub struct Transform {
    position: Spline<Vec3>,
    rotation: Spline<Quat>,
    scale: Spline<Vec3>,
}
```

This pattern enables procedural motion without keyframe bloat. Traits like `Interpolate` let users animate custom types.

### Adopt: Separate Scene-Level and Object-Level Constant Data

The two-tier constant buffer structure is smart. Scene data (camera, lights) uploads once per layer. Object data (matrices, material parameters) uploads per instance. In wgpu terms:

```rust
#[repr(C)]
struct SceneUniforms {
    view_matrix: Mat4,
    projection_matrix: Mat4,
    camera_pos: Vec4,
    light_count: u32,
    lights: [Light; 8],
    // ...
}

#[repr(C)]
struct ObjectUniforms {
    world_matrix: Mat4,
    inverse_transpose_matrix: Mat4,
    material_data: [f32; 64],
}
```

Bind group 0 holds scene uniforms. Bind group 1 holds object uniforms. Set bind group 0 once per layer, bind group 1 per instance.

### Modify: Avoid One Instance Per Pass Material Expansion

Phoenix's material expansion is correct for 64k intros but wasteful for general use. A modern engine should use multi-draw indirect:

```rust
struct RenderBatch {
    material: MaterialHandle,
    instances: Vec<InstanceData>,
}

impl RenderBatch {
    fn render(&self, encoder: &mut wgpu::CommandEncoder) {
        // Bind material pipeline and textures once
        self.material.bind(encoder);

        // Multi-draw indirect for all instances
        encoder.multi_draw_indexed_indirect(&self.instance_buffer, ...);
    }
}
```

This batches instances with identical materials, issuing one GPU command instead of hundreds. The overhead of multi-draw setup is amortized across many instances.

### Modify: Add Optional Frustum Culling

Phoenix skips culling because content is tightly authored. A general framework should make culling optional but available:

```rust
pub struct Scene {
    objects: Vec<Object>,
    spatial_index: Option<Octree>,
}

impl Scene {
    pub fn collect_visible(&self, frustum: &Frustum) -> Vec<&Object> {
        match &self.spatial_index {
            Some(octree) => octree.query_frustum(frustum),
            None => self.objects.iter().collect(),
        }
    }
}
```

Users creating open-world content enable the octree. Users creating tightly authored scenes disable it. Default to simplicity, opt into complexity.

### Modify: Consider Instancing for Repeated Geometry

Phoenix never uses hardware instancing. Every object is a separate draw call. But many scenes have repeated elements: particles, foliage, crowds. Support instancing:

```rust
struct InstancedMesh {
    mesh: MeshHandle,
    material: MaterialHandle,
    transforms: Vec<Mat4>,
}

impl InstancedMesh {
    fn render(&self, encoder: &mut wgpu::CommandEncoder) {
        // Upload instance transforms to buffer
        let instance_buffer = self.upload_instances();

        // Single draw call for all instances
        encoder.draw_indexed(
            mesh.index_range(),
            0,
            0..self.transforms.len() as u32,
        );
    }
}
```

This pattern accelerates scenes with repeated elements without forcing all content to use instancing.

### Avoid: Storing Complete GPU State in Instances

Phoenix's `CphxRenderDataInstance` holds eight texture handles, three state objects, five shader handles, two matrices, and a material data block. This is 300+ bytes per instance. For 10,000 instances, that's 3MB of redundant data.

A Rust framework should use handle-based lookups:

```rust
struct RenderInstance {
    mesh: MeshHandle,
    material: MaterialHandle,
    transform: Mat4,
    layer: LayerIndex,
}

// Materials cache pipeline and bind groups
struct Material {
    pipeline: wgpu::RenderPipeline,
    bind_group: wgpu::BindGroup,
}
```

Handles are 4-8 bytes. Instance data shrinks to 80 bytes. The material cache deduplicates pipelines and bind groups. This trades memory for one level of indirection, which modern CPUs handle well.

### Avoid: Allocating Instances Per Frame

Phoenix calls `new CphxRenderDataInstance()` hundreds of times per frame. Small allocations are fast, but not free. A Rust framework should use an arena allocator:

```rust
struct FrameArena {
    instances: Vec<RenderInstance>,
    index: usize,
}

impl FrameArena {
    fn allocate(&mut self) -> &mut RenderInstance {
        if self.index >= self.instances.len() {
            self.instances.push(RenderInstance::default());
        }
        let instance = &mut self.instances[self.index];
        self.index += 1;
        instance
    }

    fn reset(&mut self) {
        self.index = 0;  // Reuse allocations next frame
    }
}
```

Allocate once at startup, reuse every frame. This eliminates per-frame allocator churn.

## References

- `apEx/Phoenix/Timeline.cpp` — Timeline event triggering scene render
- `apEx/Phoenix/Scene.cpp` — Scene graph update, traversal, and rendering
- `apEx/Phoenix/Model.cpp` — Mesh object render instance creation
- `apEx/Phoenix/Material.cpp` — Material technique pass expansion
- `apEx/Phoenix/RenderLayer.cpp` — Final draw call execution
- `apEx/Phoenix/RenderLayer.h` — RenderDataInstance structure definition
