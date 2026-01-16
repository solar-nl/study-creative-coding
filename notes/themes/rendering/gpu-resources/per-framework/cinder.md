# Cinder: RAII and the Scoped State Stack

> How do you make GPU resources as safe as local variables?

---

## The C++ Approach

Cinder is a C++ creative coding framework, and it brings C++'s distinctive idiom—RAII (Resource Acquisition Is Initialization)—to GPU resource management. In Cinder, creating a buffer *is* allocating it; destroying it *is* freeing it. There's no separate lifecycle to manage.

This sounds obvious until you've worked with APIs where resources have independent create/use/destroy phases that can get out of sync. RAII makes a promise: if the object exists, the resource is valid. If the object is destroyed, the resource is freed. The compiler enforces this through destructors.

The question guiding this exploration: *how does C++'s ownership model apply to GPU resources, and what patterns emerge?*

---

## Shared Ownership Through Reference Counting

Cinder wraps GPU resources in `shared_ptr`:

```cpp
typedef std::shared_ptr<class BufferObj> BufferObjRef;

BufferObj::BufferObj( GLenum target, GLsizeiptr allocationSize, const void *data, GLenum usage )
    : mId( 0 ), mTarget( target ), mSize( allocationSize ), mUsage( usage )
{
    glGenBuffers( 1, &mId );
    ScopedBuffer bufferBind( mTarget, mId );
    glBufferData( mTarget, mSize, data, mUsage );
    gl::context()->bufferCreated( this );
}

BufferObj::~BufferObj()
{
    auto ctx = gl::context();
    if( ctx )
        ctx->bufferDeleted( this );
    glDeleteBuffers( 1, &mId );
}
```

The GL buffer is created in the constructor, deleted in the destructor. Pass the `BufferObjRef` around, clone it, store it in multiple places—the buffer lives as long as any reference exists. When the last reference drops, the destructor runs automatically.

This is the same Arc pattern that wgpu and nannou use, but expressed through C++'s native smart pointer. The semantics are identical: shared ownership, automatic cleanup, thread-safe reference counting.

---

## The Scoped Binding Stack

OpenGL has global state: the "currently bound" buffer, texture, framebuffer. Operations implicitly affect whatever is currently bound. This is error-prone—bind the wrong thing, and your operation corrupts unrelated state.

Cinder introduces scoped bindings that manage this state automatically:

```cpp
struct ScopedBuffer : public Noncopyable {
    ScopedBuffer( const BufferObjRef &bufferObj )
        : mCtx( gl::context() ), mTarget( bufferObj->getTarget() )
    {
        mCtx->pushBufferBinding( mTarget, bufferObj->getId() );
    }

    ~ScopedBuffer()
    {
        mCtx->popBufferBinding( mTarget );
    }

private:
    Context *mCtx;
    GLenum mTarget;
};
```

Create a `ScopedBuffer`, and the buffer is bound. When the scope exits—normally or via exception—the destructor pops the binding, restoring the previous state.

Usage looks like this:

```cpp
void BufferObj::bufferData( GLsizeiptr size, const GLvoid *data, GLenum usage )
{
    ScopedBuffer bufferBind( mTarget, mId );  // Bind on entry
    mSize = size;
    mUsage = usage;
    glBufferData( mTarget, mSize, data, usage );
}  // Unbind on exit
```

The binding is guaranteed to be correct within the scope, and guaranteed to be restored after. No manual unbinding, no risk of forgetting, no state corruption from early returns or exceptions.

Cinder provides scoped wrappers for most bindable resources: `ScopedVao`, `ScopedTextureBind`, `ScopedFramebuffer`, `ScopedGlslProg`. The pattern is universal.

---

## Context Tracking for Diagnostics

Cinder's `Context` class tracks all GPU resources:

```cpp
void bufferCreated( const BufferObj *buffer );
void bufferDeleted( const BufferObj *buffer );
void textureCreated( const TextureBase *texture );
void textureDeleted( const TextureBase *texture );
```

Every resource registers itself on creation and unregisters on destruction. This enables:
- Debug validation: catch use-after-delete, detect leaks
- Memory tracking: know how much GPU memory is allocated
- Hot-reload: know what resources exist when recreating context

The context also maintains the binding stack that makes scoped bindings work:

```cpp
void pushBufferBinding( GLenum target, GLuint id );
void popBufferBinding( GLenum target );
```

Each binding target (array buffer, element buffer, uniform buffer, etc.) has its own stack. Push binds the resource; pop restores whatever was bound before.

---

## Texture Pooling: Custom Deleters

Cinder's `Texture2dCache` demonstrates a sophisticated pooling pattern using custom deleters:

```cpp
class Texture2dCache {
    int mNextId;
    std::vector<std::pair<int, TextureRef>> mTextures;  // -1 = free

    TextureRef cache( const Surface8u &data ) {
        // Find available slot
        for( auto &texPair : mTextures ) {
            if( texPair.first == -1 ) {  // Available!
                texPair.second->update( data );
                texPair.first = mNextId++;
                // Custom deleter returns to pool instead of destroying
                return TextureRef( texPair.second.get(),
                    std::bind( &Texture2dCache::markTextureAsFree,
                               shared_from_this(), texPair.first ) );
            }
        }

        // No free slot, create new texture
        TextureRef masterTex( new Texture( data, mFormat ) );
        mTextures.push_back( make_pair( mNextId++, masterTex ) );
        return TextureRef( mTextures.back().second.get(),
            std::bind( &Texture2dCache::markTextureAsFree,
                       shared_from_this(), mTextures.back().first ) );
    }

    void markTextureAsFree( int id ) {
        for( auto &texPair : mTextures ) {
            if( texPair.first == id ) {
                texPair.first = -1;  // Mark free for reuse
                break;
            }
        }
    }
};
```

The magic is in `shared_ptr`'s custom deleter. When you get a texture from the cache, it comes with a deleter that doesn't call `glDeleteTextures`—instead, it marks the slot as available for reuse.

From the user's perspective, the texture works like any other `TextureRef`. They don't know it's pooled. When their reference drops, the texture returns to the pool silently. The pool manages GPU memory; users manage lifetimes.

---

## Opt-Out Disposal for External Resources

Sometimes you wrap resources you don't own—a texture from a camera feed, a buffer from another library:

```cpp
class TextureBase {
    bool mDoNotDispose;

    ~TextureBase() {
        if( ( mTextureId > 0 ) && ( ! mDoNotDispose ) ) {
            glDeleteTextures( 1, &mTextureId );
        }
    }

    void setDoNotDispose( bool doNotDispose = true ) {
        mDoNotDispose = doNotDispose;
    }
};
```

Set `doNotDispose`, and the destructor skips the GL delete call. The texture wrapper gets destroyed, but the underlying GL resource persists—owned by whoever actually created it.

This is defensive API design. Cinder's ownership model is shared_ptr-based, but not everything fits that model. The opt-out provides an escape hatch.

---

## Batch Rendering: Composing Resources

Cinder's `Batch` class bundles resources that belong together:

```cpp
class Batch {
    gl::GlslProgRef mGlsl;
    VboMeshRef mVboMesh;
    VaoRef mVao;

    void draw( GLint first, GLsizei count ) {
        auto ctx = gl::context();
        gl::ScopedGlslProg scopedShader( mGlsl );
        gl::ScopedVao scopedVao( mVao );
        ctx->setDefaultShaderVars();
        mVboMesh->drawImpl( first, count );
    }
};
```

A Batch combines mesh data (VboMesh), shader program (GlslProg), and vertex attribute layout (VAO). Drawing the batch binds everything correctly, sets shader uniforms, and issues the draw call.

This is the "bundle related resources" pattern from nannou, but more elaborate. The batch encapsulates not just data but the entire rendering configuration. Users draw batches; Cinder handles the binding choreography.

---

## Modern OpenGL Support

Cinder supports both traditional and modern OpenGL:

```cpp
BufferObj::BufferObj( GLenum target, GLsizeiptr allocationSize, ... )
{
    bool initialized = false;
#if defined( GL_VERSION_4_5 )
    if( GLAD_GL_VERSION_4_5 ) {
        glCreateBuffers( 1, &mId );  // Direct State Access
        glNamedBufferData( mId, mSize, data, mUsage );
        initialized = true;
    }
#endif
    if( ! initialized ) {
        glGenBuffers( 1, &mId );
        ScopedBuffer bufferBind( mTarget, mId );
        glBufferData( mTarget, mSize, data, mUsage );
    }
}
```

On OpenGL 4.5+, Cinder uses Direct State Access (DSA)—operations that specify which resource to affect rather than relying on global bindings. DSA is more efficient (fewer state changes) and safer (no accidental state pollution).

But DSA isn't universally available, so Cinder falls back to traditional bind-then-operate on older drivers. The same pattern appears throughout: try modern path first, fall back gracefully.

---

## Lessons for the GPU Resource Pool

Cinder's patterns suggest several approaches:

**RAII for resource lifecycles.** In Rust, this means Drop traits. Resources are valid while they exist; destruction is automatic. No separate create/destroy phases to get out of sync.

**Scoped state management.** For mutable state management (less common in wgpu than OpenGL, but possible), scoped guards ensure cleanup. Rust's RAII maps perfectly to this.

**Custom deleters for pooling.** Rust's Arc doesn't support custom deleters as elegantly as shared_ptr, but similar patterns are possible with explicit pool return mechanisms.

**Context tracking for diagnostics.** Registering resources on creation enables memory tracking, leak detection, and debugging. Worth considering for development builds.

**Bundle related resources.** Mesh + shader + layout belong together. Encapsulating them reduces API surface and prevents mismatched state.

**Graceful degradation.** Support modern paths (wgpu's native features) while falling back on older ones where needed. Not directly applicable to wgpu, but the principle matters for portability.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `include/cinder/gl/BufferObj.h` | 33-114 | Buffer RAII wrapper |
| `src/cinder/gl/BufferObj.cpp` | 31-89 | Buffer allocation/deallocation |
| `include/cinder/gl/scoped.h` | 43-127 | Scoped binding declarations |
| `src/cinder/gl/scoped.cpp` | 35-71 | Scoped binding implementation |
| `include/cinder/gl/Texture.h` | 47-72, 797-817 | Texture ownership, pooling |
| `src/cinder/gl/Texture.cpp` | 133-154, 1556-1616 | Texture lifecycle, cache |
| `include/cinder/gl/Batch.h` | 41-98 | Batch rendering |
| `include/cinder/gl/Context.h` | 164-166, 288-290 | Resource tracking |

---

## Related Documents

- [wgpu.md](wgpu.md) — Similar Arc patterns in Rust
- [nannou.md](nannou.md) — Bundled resources pattern
- [../handle-designs.md](../handle-designs.md) — Handle pattern comparison
