# apEx Size Optimization

You build a complete 3D demo with procedural meshes, multi-pass shaders, particle systems, and synchronized music. It renders complex scenes at 60fps with bloom, depth of field, and dynamic lighting. The executable fits in 65,536 bytes. This is what demoscene size optimization looks like.

Demoscene competition rules establish the 64KB constraint, dating back to when 64 kilobytes was the size of early computer memory. Modern demos run on hardware thousands of times more powerful, but the size limit remains. Think of it like writing a haiku. The constraint is the point. The art emerges from working within extreme limitations.

The challenge is brutal. A minimal Windows executable that just creates a window and exits is roughly 2KB after compression. Load DirectX 11, initialize a swap chain, compile shaders, allocate vertex buffers, and play audio? You've consumed 20KB before writing a single line of demo code. A single uncompressed 256x256 RGBA texture is 256KB, four times your entire budget. One second of CD-quality stereo audio is 176KB, nearly three times your limit. Standard library overhead from C++ iostreams, exceptions, and RTTI can add 100KB to your binary. The 64KB constraint means you cannot use normal development practices.

apEx solves this through aggressive elimination. Every byte counts. The team replaces the standard C runtime library with handwritten assembly. They write a custom HLSL minifier that manipulates shader ASTs to remove dead code and shorten identifiers. They compress the final executable with kkrunchy, a packer specifically designed for demoscene executables that achieves 8-10x compression ratios. They generate all content procedurally, storing mathematical functions instead of image data. They merge PE sections, disable security features, and remove every C++ feature that adds binary overhead. These techniques combine to turn what would naturally be a 500KB executable into 63KB.

## The Problem: Why 64KB is Extreme

A modern C++ application has massive overhead before you write application code. The Visual C++ runtime library provides memory allocation, exception handling, runtime type information, iostreams, and string manipulation. Linking against the standard library adds roughly 100KB to a release build. Even with aggressive optimization, a "hello world" console application compiles to 50KB before compression.

Graphics APIs add more weight. DirectX 11 requires importing d3d11.dll, d3dcompiler_47.dll, and dxgi.dll. The import table alone, listing every function your executable calls, can be several kilobytes. Shader compilation at runtime means shipping HLSL source code strings, which compress poorly because they contain verbose identifiers and whitespace. Compiling shaders offline means storing bytecode, which is better but still bulky. A single fullscreen shader with lighting calculations can compile to 2-3KB of bytecode.

Content is the biggest problem. Game development typically stores textures as PNG or DDS files embedded in resources. A 512x512 diffuse texture compressed with DXT1 is 128KB. Normal maps are larger because they need more precision. Environment maps need six faces. Mesh data contains vertex positions, normals, tangents, and UV coordinates, easily 1KB for a simple cube. Animation data, sound effects, music tracks, and UI elements all require storage. A minimal asset package for a simple 3D scene is hundreds of kilobytes.

The standard solution is data compression. Tools like zlib or lz4 compress PNG textures by 20-30% and executable code by 40-50%. This helps but doesn't solve the fundamental problem. Compressed, a basic 3D demo with a few meshes, textures, shaders, and a music track is still 200-300KB. To reach 64KB requires eliminating entire categories of data and code.

## LibCTiny: Tiny C Runtime

Understanding the overhead problem leads directly to the first major optimization: replacing Microsoft's C runtime library. The MSVC runtime provides functions like `printf`, `malloc`, `memset`, trigonometric functions, and C++ operators like `new` and `delete`. It also contains initialization code that sets up the process heap, handles command line arguments, and calls global constructors. This infrastructure is essential for normal C++ programs but adds 80-120KB to the final executable.

LibCTiny is apEx's replacement. It implements only the functions 64k demos actually use, with minimal or no error checking. The entire library is under 800 lines of code. Memory allocation calls the Windows API directly via `HeapAlloc` and `HeapFree`. Mathematical functions like `sin`, `cos`, `sqrt`, and `pow` use inline x86 FPU assembly instructions rather than calling library implementations. C++ operators `new` and `delete` are trivial wrappers around heap allocation. String formatting exists only in debug builds via a minimal `sprintf2` implementation that handles integers and strings but not floating point.

The startup code is particularly lean. Normal C runtime startup does extensive initialization: setting up the heap, parsing command line arguments, initializing locale data, setting up exception handlers, and calling static constructors. LibCTiny's `WinMainCRTStartup` does two things: call static constructors via `_initterm(__xc_a, __xc_z)`, then call `WinMain`. No argument parsing, no locale setup, no exception handling. When the demo exits, it calls `ExitProcess(0)` directly, skipping cleanup. The OS reclaims all memory and resources, so explicit deallocation is unnecessary.

Mathematical functions demonstrate the extreme size focus. Here's the complete implementation of cosine:

```cpp
float __declspec(naked) cos() {
  _asm {
    fld qword ptr[esp + 4]
    fcos
    ret
  };
};
```

This is six lines of assembly. No error checking, no argument validation, no handling of edge cases like infinity or NaN. Just load the argument onto the FPU stack, execute the `fcos` instruction, and return. The Visual C++ runtime implementation of `cos` is roughly 200 lines with precision handling, range reduction, and special case logic. For demos, the FPU instruction is accurate enough and 50 times smaller.

The `floor` function is similarly minimal:

```cpp
double floor(double f) {
  const float half = -0.5f;
  int i;
  __asm {
    fld f
    fadd st, st(0)
    fadd half
    fistp i
    sar i, 1
  };
  return float(i);
}
```

This uses FPU rounding modes to truncate values instead of calling a library function. It's not IEEE-754 compliant. It doesn't handle negative zero or denormals correctly. But for demo purposes, converting floats to integers for array indexing or loop counts, it works perfectly and compiles to a handful of instructions.

The linker configuration completes the picture. The project file specifies `/NODEFAULTLIB`, which prevents linking against msvcrt.dll. Instead, it links against `msvcrt_mini.lib`, a custom import library built from `msvcrt.def` that exports only the symbols LibCTiny doesn't implement. Functions like `qsort` and `memcpy` still come from the system library because they're complex enough that reimplementation doesn't save space. But by cherry-picking imports and implementing the rest in minimal inline assembly, LibCTiny reduces runtime library overhead from 100KB to roughly 2KB.

## Shader Minification: HLSL AST Manipulation

Shaders are the visual heart of demos, and shader code is expensive. A typical HLSL pixel shader with Blinn-Phong lighting, normal mapping, and specular highlights is 50-100 lines of code. Compiled to bytecode, this becomes 2-4KB. A demo with 20 material passes means 40-80KB of shader bytecode, more than the entire 64KB budget.

apEx solves this with aggressive shader minification. The tool parses HLSL source code into an abstract syntax tree using a parser lifted from Unreal Engine 4. Once the shader is in AST form, the minifier performs transformations that reduce code size while preserving semantics. The key operations are dead code elimination, identifier shortening, constant folding, and expression simplification.

Dead code elimination removes unused functions, variables, and inputs. HLSL shaders often include helper functions that only certain material types use. A shader library might have functions for parallax occlusion mapping, subsurface scattering, and anisotropic highlights. Most materials use only one or two of these. The minifier analyzes the AST, identifies which functions the entry point actually calls, and removes everything else. This alone can halve shader code size.

Identifier shortening replaces verbose variable names with single-character names. Shader artists name variables descriptively: `worldPosition`, `normalMapSample`, `specularPower`. These names aid readability but waste bytes. The minifier renames `worldPosition` to `a`, `normalMapSample` to `b`, and so on. Semantics like `SV_Position` and `TEXCOORD0` cannot be renamed because the GPU expects them, but user variables shrink dramatically.

Constant folding evaluates compile-time constant expressions. If a shader contains `float x = 2.0 * 3.14159;`, the minifier replaces it with `float x = 6.28318;`. More subtly, if a shader has a constant that's only used once, the minifier inlines it at the use site and removes the declaration. This reduces variable declarations and simplifies the constant buffer layout.

Expression simplification applies algebraic identities. `x * 1.0` becomes `x`. `normalize(v) * length(v)` becomes `v` because normalization divides by length, then we multiply by length, canceling out. These transformations require semantic understanding of HLSL intrinsics, which the AST parser provides. The minifier traverses the expression tree, matches patterns, and replaces them with simplified equivalents.

The minified shader compiles to bytecode, which then compresses with the rest of the executable. Shorter identifiers and fewer instructions mean less bytecode, which compresses better. A well-minified shader might reduce from 3KB of bytecode to 1KB, and that 1KB might compress to 200-300 bytes in the final executable. Across 20 shaders, this saves 40-50KB before compression, which translates to 8-10KB in the final build.

## Executable Compression: kkrunchy and rekkrunchy

After reducing code and eliminating data overhead, executable packing provides the final compression layer. apEx uses kkrunchy, a compressor written by Fabian Giesen specifically for demoscene executables. Unlike general-purpose compressors like zip or lz4, kkrunchy understands PE executable format and applies domain-specific transformations before compression.

The packer operates in three stages: preprocessing, compression, and depacker embedding. Preprocessing analyzes the executable structure. PE files contain multiple sections: .text for code, .data for initialized data, .rdata for read-only data, .rsrc for resources. kkrunchy merges sections where possible to improve compression ratios. Code and read-only data compress better together because they share similar statistical properties. It also analyzes imports and reorders them to group related functions, improving compression locality.

The compressor uses a variant of LZMA called "LZMA with x86 filtering." Standard LZMA compresses byte sequences by finding repetitions and encoding them as back-references. X86 code compresses poorly with standard LZMA because relative jumps and calls have addresses that change during compilation, breaking repetition. X86 filtering transforms call and jump instructions to use relative offsets instead of absolute addresses before compression. This dramatically improves compression ratios for code sections.

kkrunchy also applies statistical modeling to prioritize common code patterns. Demoscene executables heavily use DirectX API calls, which have predictable patterns: push arguments, call function, check result. The compressor learns these patterns and encodes them efficiently. For demo code, this achieves 8-10x compression ratios. A 200KB uncompressed executable becomes 20-25KB compressed.

The depacker is a tiny assembly stub that extracts the compressed data at runtime. When the packed executable launches, the depacker runs first. It allocates memory, decompresses the original executable in-place, fixes up import tables and relocations, then jumps to the real entry point. The depacker itself is roughly 1.5KB of hand-optimized assembly. This overhead is acceptable because it enables compressing the other 60KB.

rekkrunchy is an improved version that uses newer compression algorithms and better preprocessing. It analyzes code sequences to identify common patterns specific to the C++ compiler's output, then creates custom dictionaries for those patterns. This improves compression by another 10-15%. The trade-off is longer compression time and a slightly larger depacker stub. For final releases where every byte counts, teams use rekkrunchy and spend minutes compressing to save a few hundred bytes.

The packer includes debug features that help track size usage. It generates a report showing how many bytes each source file contributes to the final compressed size. Teams use this to identify bloated code. If one material shader compresses to 5KB while others are 1-2KB, the shader is probably doing something inefficient or using functions that don't compress well. This feedback loop helps teams optimize iteratively.

## Procedural Content Generation

Procedural generation eliminates data storage entirely by computing content from algorithms. Instead of storing a 512x512 texture (256KB uncompressed), apEx stores a small program that generates the texture at startup. A Perlin noise function with a few parameters can generate an infinite variety of textures. The code to generate noise is perhaps 500 bytes. The resulting texture data exists only in RAM at runtime, never in the executable.

The Phoenix engine includes several procedural generators. The texture generator creates 2D textures using mathematical functions and filters. Artists define textures as node graphs in the tool. A node might be a gradient, a noise function, a Voronoi cell pattern, or an image filter like blur or sharpen. The tool evaluates this graph to generate the texture, then serializes the graph structure as binary data. The runtime reads this data and regenerates the texture using the same algorithms. The graph structure is typically 100-500 bytes per texture. The actual texture data never exists in the executable.

The tree generator creates 3D tree geometry using L-system-like rules. An L-system is a formal grammar that recursively expands symbols. Start with a trunk symbol. Replace it with "trunk, branch left, branch right." Replace each branch with smaller branches. After several iterations, you have a tree structure. The generator adds randomness for variation, then converts the symbolic representation to triangles. A complete tree mesh with thousands of triangles can be generated from 50-100 bytes of rule data plus a random seed.

Mesh modifiers apply transformations to base geometry. The tool includes subdivision, extrusion, bending, twisting, and noise deformation. Artists start with a simple primitive like a cube or sphere, apply modifiers, and create complex shapes. The executable stores the modifier stack, not the final geometry. At runtime, the engine applies each modifier in sequence, generating the final mesh. This is slower than loading prebuilt geometry but far smaller. A complex mesh might be 50KB as vertex data but only 500 bytes as a modifier stack.

Music synthesis uses procedural audio via WaveSabre or similar synthesizers. Instead of storing MP3 or OGG audio data, demos store note sequences, synthesis parameters, and effect chains. The synthesizer generates audio in real time during playback. A 3-minute music track as OGG is roughly 2-3MB. As WaveSabre data, the same track is 10-50KB. The trade-off is CPU cost. Synthesis consumes significant processing power, but modern CPUs can handle it while maintaining 60fps rendering.

The challenge with procedural generation is iteration time. Generating a texture at startup takes milliseconds. For a demo with 50 textures, that's a second or two of loading time. Artists tolerate this in the authoring tool but not during iteration. apEx solves this with the precalc system. The tool pre-generates assets and saves them to a cache. During development, demos load from cache for fast iteration. For release builds, the cache is discarded and generation runs at startup. This workflow gives artists fast tools while keeping final executables small.

## Data Serialization: Compact Binary Format

Once content is generated or authored, it must serialize to the executable. apEx uses an extremely compact binary format optimized for size, not readability or compatibility. The format has minimal metadata. Arrays store a count followed by raw elements. Strings store a length byte followed by characters, no null terminator. Objects store a type tag, then fields in a fixed order defined by the code. No field names, no version tags, no alignment padding.

Consider a simple scene with 10 objects, each with a position, rotation, and scale. A JSON representation might look like:

```json
{
  "objects": [
    {"position": [1.0, 2.0, 3.0], "rotation": [0.0, 0.0, 0.0, 1.0], "scale": [1.0, 1.0, 1.0]},
    ...
  ]
}
```

This is roughly 300 bytes for 10 objects, with significant overhead from field names, brackets, and formatting. The apEx binary format stores:

```
[count: 10]
[x: float][y: float][z: float]  // position
[x: float][y: float][z: float][w: float]  // rotation quaternion
[x: float][y: float][z: float]  // scale
... (repeat 9 times)
```

This is exactly 400 bytes: 4 bytes for count, then 10 * (3 + 4 + 3) * 4 = 400 bytes of float data. No field names, no brackets, no whitespace. The code knows the structure, so the data contains only values.

Splines serialize even more compactly using 16-bit floats. A spline with 4 keyframes stores timestamps and values. With 32-bit floats, that's 4 * (4 + 4) = 32 bytes. With 16-bit floats, it's 4 * (2 + 2) = 16 bytes. Half-precision floats have limited range and precision, but for animation curves that interpolate smoothly between keyframes, the quality loss is imperceptible. Across hundreds of splines, this halves animation data size.

The material system stores shader bytecode directly instead of HLSL source. Compilation happens in the tool, not at runtime. The tool compiles shaders with D3DCompiler, strips debug information and reflection data, then stores the raw bytecode. This is more compact than source and faster to load. It also eliminates the need to ship the D3D compiler DLL with the demo.

Resource references use 16-bit indices instead of pointers or strings. If a material references textures, it stores texture indices into a global texture array. The runtime resolves indices to actual texture objects during load. This keeps references small and avoids pointer fixup issues.

The serialization system omits error checking entirely. Corrupt data causes crashes or garbage rendering. This proves acceptable for demos because artists control the full pipeline. They test thoroughly before release. Robustness isn't a goal. Minimum size is the only goal.

## Linker Optimization: Section Merging and Dead Code Elimination

The Visual C++ linker has numerous size optimization features that apEx exploits. The most impactful are function-level linking, COMDAT folding, and section merging.

Function-level linking enables dead code elimination at the function granularity. Normally, the linker includes an entire object file if any symbol in it is referenced. With `/Gf` (function-level linking), each function is placed in its own section. The linker can discard sections that nothing references. This is essential for template-heavy code where instances of unused template specializations would otherwise bloat the binary.

COMDAT folding merges identical functions. If two functions compile to identical machine code, the linker keeps one copy and redirects all calls. This commonly happens with small inline functions and template instantiations. A demo might instantiate `std::min<float>` hundreds of times. Each instantiation produces identical code. COMDAT folding reduces hundreds of copies to one. The space savings are significant in templated C++.

Section merging combines PE sections to reduce overhead. Each section has a header with alignment, flags, and size information. The PE format aligns sections to 4KB boundaries by default. If you have ten small sections, you waste kilobytes on padding. apEx uses `/MERGE:.rdata=.text` to combine read-only data with code. This eliminates one section header and one alignment gap, saving 4-8KB.

The linker also supports base address configuration to reduce relocations. Windows supports Address Space Layout Randomization (ASLR) for security. When ASLR is enabled, the loader relocates the executable to a random address at runtime. Each relocation requires fixing up pointers, and the relocation table adds to executable size. By setting `/FIXED:NO` and specifying a non-standard base address like `0x600000`, apEx reduces relocation table size. Demos don't benefit from ASLR, so disabling it saves bytes.

Import libraries are minimized using custom `.def` files. The msvcrt.def file lists only the symbols apEx actually imports from msvcrt.dll. Instead of importing the entire C runtime, it imports 5-10 functions like `qsort` and `memcpy` that are cheaper to import than reimplement. This reduces import table size from several kilobytes to a few hundred bytes.

Map file analysis helps identify bloat. The linker generates a map file showing every symbol's size. Teams grep this file for large symbols and investigate. If a utility function is 10KB, maybe it's doing too much or calling functions with poor compression. This feedback drives code refactoring.

## Compiler Flags: Optimization for Size

The Visual C++ compiler supports size-focused optimization modes. apEx uses `/Os` (optimize for size) instead of `/Ot` (optimize for speed). This instructs the compiler to favor smaller code generation patterns. For example, loops might use more instructions but reuse register state to avoid stack spills. Function calls replace inline expansions when the inline expansion is larger than a call instruction.

The project disables several language features that add overhead:

- `/EHs-` disables C++ exceptions. Exceptions require tables mapping code addresses to exception handlers. Even if you never throw, the tables exist. Disabling exceptions removes these tables and the stack unwinding code. apEx uses return codes and asserts instead.

- `/GR-` disables runtime type information. RTTI enables `dynamic_cast` and `typeid`, which require storing type names and inheritance hierarchies. Demos use static polymorphism via templates or manual type tags instead.

- `/GS-` disables buffer security checks. Normally, the compiler adds stack canaries to detect buffer overflows. Each function with local arrays gets extra code to set and check canaries. This adds security but costs bytes. Demos are not network-facing or security-critical, so they disable this.

Calling convention matters for code density. `/Gr` specifies the `__fastcall` convention, which passes the first two arguments in registers instead of on the stack. This reduces stack manipulation instructions, making functions smaller. It also makes functions faster, but the size benefit is the primary reason apEx uses it.

Inline function expansion is carefully controlled. `/Ob2` allows aggressive inlining, which can improve performance but increases code size. apEx uses `/Ob1` (inline only functions marked `__inline`) to prevent the compiler from inlining everything. Teams mark hot functions for inlining manually, keeping control over code size.

Float-to-integer conversion uses `/Qfast_transcendentals` and disables denormal handling. IEEE 754 requires handling denormal numbers (values smaller than the smallest normalized float). This requires checks in arithmetic operations. For demos, denormals never occur, so the checks are pure overhead. Disabling denormal support removes these checks.

The compiler also supports intrinsics that replace library calls. `memcpy` and `memset` can use compiler intrinsics that expand to a few instructions instead of calling a function. For small copies, this is faster and smaller than a call. The compiler chooses automatically when `/Oi` (enable intrinsics) is set.

## Trade-offs: What apEx Sacrifices

Every optimization carries consequences. apEx sacrifices many things normal applications rely on to achieve its size targets.

The team implements minimal error handling. Functions do not check for null pointers, invalid arguments, or out-of-bounds array access. If something goes wrong, the demo crashes. Artists test thoroughly, and demos run on known hardware, so this is acceptable. But it makes debugging difficult. Crashes provide no context, just an access violation address.

Release builds strip all debugging information. The `.pdb` file exists during compilation for analysis but never ships with the final executable. Stack traces are meaningless. The only way to debug release builds is to run uncompressed debug builds, which behave slightly differently. This makes reproducing field issues hard.

The team sacrifices platform compatibility entirely. apEx targets 64-bit Windows 10 with DirectX 11 exclusively. It doesn't run on Windows 7 without patches, on Linux, or on older GPUs. The team doesn't test alternate configurations. This is acceptable for party releases where the hardware configuration is known.

Maintainability suffers from aggressive size optimization. Code uses single-letter variable names in shaders, merges unrelated data structures to save padding bytes, and relies on compiler-specific behavior. Reading the code is hard. Modifying it without introducing bugs is harder. Demoscene teams accept this because they work on a project for months, release it, then move on. Long-term maintenance isn't a concern.

Load times are longer due to procedural generation. A typical demo has a 5-10 second loading screen where it generates textures, meshes, and trees. Commercial games precompute everything for instant loading. Demos accept slow startup because the 64KB constraint forces procedural generation.

Iteration time is slower. Every change requires recompiling, repacking with kkrunchy, and running the 5-second loading process. Compare to game development where hot reload swaps assets in under a second. apEx mitigates this with the precalc system, but iteration is still slower than asset-based pipelines.

## Size Budgeting: Allocating Bytes Across Systems

apEx teams explicitly budget bytes across subsystems. A typical 64KB demo might allocate:

- **Runtime code** (Phoenix engine, LibCTiny): 15KB
- **Shader bytecode**: 8KB
- **Procedural texture generators**: 5KB
- **Mesh data and modifiers**: 6KB
- **Animation splines**: 4KB
- **Music synthesizer and song data**: 20KB
- **Resources (fonts, textures)**: 3KB
- **Depacker stub**: 1.5KB

This leaves roughly 2-3KB of margin for last-minute additions. Teams track byte usage continuously via linker map files and compression reports. If music data grows to 25KB, shader budget must shrink to compensate.

Budgeting drives design decisions. If a visual effect requires 3KB of shader code, the team evaluates whether it's worth 3KB. Can a simpler effect achieve 80% of the visual quality for 1KB? Often, yes. Constraints force creativity. Teams find clever tricks that look good and compress well.

One technique is reusing shaders with different parameters. Instead of writing separate shaders for metal, glass, and plastic, write one shader with material constants. At runtime, bind different constant buffers. This costs a few bytes of constant data but saves kilobytes of shader code.

Another technique is multi-purpose geometry. A rock mesh can double as a cliff face with different scaling and texturing. One tree generator can create multiple tree species with different parameters. Reusing generators and meshes saves more than bytes. It saves the complexity of managing many assets.

Music often consumes the largest chunk. A three-minute synthesized track with multiple instruments, automation, and effects can easily reach 30-40KB. Teams negotiate with musicians. Can the track be 2:30 instead of 3:00? Can one instrument be dropped? These conversations are uncomfortable but necessary.

## Implications for Creative Coding Frameworks

The techniques apEx uses are extreme, but several lessons apply to creative coding frameworks aiming for efficient distribution.

**Procedural generation as default**. Frameworks should encourage generating content algorithmically rather than storing baked assets. Provide noise functions, shape primitives, and modifiers as first-class abstractions. Make it easier to define a texture as a formula than to load a PNG. This not only saves space but enables infinite variation and runtime customization.

**Separate tool and runtime layers**. apEx's cleanest design decision is isolating tooling from the runtime player. The authoring tool is megabytes, uses GUI libraries, and imports every codec. The runtime player strips all of that, compiling only the minimal engine. Rust frameworks should embrace this split. Cargo features can toggle between full development builds with all tools and minimal release builds with only the execution engine.

**Optimize for compression, not raw size**. apEx doesn't obsess over making uncompressed binaries small. It optimizes for compressed size by making code regular and data dense. Frameworks should profile what compresses well. Verbose debug strings compress poorly. Regular data patterns with predictable structure compress excellently. Design serialization formats for compression, not human readability.

**Compiler flags as ergonomics layer**. Rust frameworks should expose compiler and linker options through project configuration, not require manual `RUSTFLAGS` editing. A `minsize` profile in Cargo.toml could enable LTO, strip symbols, optimize for size (`opt-level = "z"`), and configure the linker for minimal output. Make size optimization one command, not ten flags.

**Shader compilation in tooling**. apEx compiles shaders offline and stores bytecode. Rust frameworks targeting wgpu should do the same. Use `naga` at build time to compile WGSL to SPIR-V, then embed bytecode. This eliminates runtime compilation overhead and makes the shader pipeline faster and smaller.

**Profile-guided optimization with demos**. kkrunchy analyzes executable structure to improve compression. Frameworks could provide analysis tools that show developers where bytes are spent. A `cargo size-profile` command that breaks down binary size by crate and function would help developers optimize iteratively.

**Avoid the apEx extremes**. LibCTiny demonstrates what's possible but also what's inadvisable. Replacing standard library math functions with unchecked FPU assembly is not a best practice outside 64KB demos. Rust frameworks should provide size optimization without sacrificing safety or correctness. Use existing compression tools like UPX or wasm-opt rather than custom packers. Strip debug info with standard flags. Enable LTO and panic=abort. These are safe, supported, and effective.

## Comparative Observations

apEx's size optimization techniques sit at an extreme few frameworks approach.

**Versus web frameworks (three.js, Babylon.js)**. Web applications target 100-500KB compressed JavaScript bundles. Framework code, libraries, and application logic compress well with gzip or brotli. apEx achieves similar compression ratios but applies them to a problem ten times more constrained. Web developers minify JavaScript, apEx minifies HLSL. Web developers tree-shake libraries, apEx eliminates the entire standard library. The techniques are philosophically similar but apEx pushes each technique to an extreme.

**Versus game engines (Unity, Godot)**. Game engines prioritize asset management and runtime flexibility. Executables are tens of megabytes. Downloadable content is gigabytes. Size optimization focuses on texture compression (BC7, ASTC) and streaming to reduce memory footprint, not executable size. apEx inverts this. Executable size is everything. Runtime flexibility is irrelevant. Games need to load arbitrary content. Demos are fixed experiences, so everything bakes into the binary.

**Versus minimal frameworks (raylib, LOVE2D)**. Minimal frameworks aim for small distributions, typically 1-10MB executables for simple games. They achieve this by avoiding heavy dependencies and using static linking. apEx uses similar techniques (static linking, minimal dependencies) but goes 100x further. raylib includes a software rasterizer. apEx has no fallback, only DirectX 11. LOVE2D interprets Lua. apEx compiles to native code and strips the compiler.

**Versus shaders (Shadertoy)**. Shadertoy demos run entirely in fragment shaders with a tiny JavaScript wrapper. The visual content is a mathematical function evaluated per pixel. This achieves extreme compactness, limited only by the JavaScript runtime. apEx demos are more complex, supporting 3D geometry, multi-pass rendering, and audio, but the HLSL minification apEx performs parallels Shadertoy's reliance on compact shader code.

The unifying theme is that size constraints force explicit choices. When bytes are infinite, developers default to convenience. When bytes are scarce, every decision is deliberate. apEx demonstrates what's possible when size becomes the primary constraint, not an afterthought.

## References

- `demoscene/apex-public/apEx/LibCTiny/libcminimal.cpp` — Minimal C runtime (line 23-549)
- `demoscene/apex-public/apEx/LibCTiny/libcminimal.h` — Debug logging macros
- `demoscene/apex-public/apEx/MinimalPlayer/MinimalPlayer.cpp` — Release executable entry point (line 85-315)
- `demoscene/apex-public/apEx/MinimalPlayer/MinimalPlayer.vcxproj` — Build configuration for 64k release (line 155-196)
- `demoscene/apex-public/apEx/MinimalPlayer/msvcrt.def` — Custom CRT import definitions
- `demoscene/apex-public/apEx/Utils/kkrunchy/main.cpp` — kkrunchy packer command line interface (line 60-190)
- `demoscene/apex-public/apEx/Utils/kkrunchy/exepacker.cpp` — PE packing implementation (line 1-150)
- `demoscene/apex-public/apEx/apEx/HLSLParser.cpp` — HLSL minification AST parser (line 1-200)
- `demoscene/apex-public/apEx/Phoenix/Texgen.h` — Procedural texture generation
- `demoscene/apex-public/apEx/Phoenix/TreeGen.h` — Procedural tree generation
- `notes/per-demoscene/apex-public/architecture.md` — apEx system architecture overview
