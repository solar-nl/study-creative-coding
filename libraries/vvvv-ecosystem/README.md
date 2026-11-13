# vvvv Ecosystem

Libraries for vvvv gamma, the .NET visual programming environment. The IDE itself is not open source; its standard node libraries are.

## Libraries

| Library | Description |
|---------|-------------|
| [VL.StandardLibs](./VL.StandardLibs/) | Standard node libraries: VL.Core, VL.CoreLib, VL.Skia (2D on SkiaSharp), VL.Stride (3D), VL.ImGui |

## About VL.StandardLibs

VL.Skia is the part under study: a 2D engine that exposes Skia's imaging model as a tree of layers, each of which both renders and handles input. Skia runs on the GPU through ANGLE (EGL over Direct3D), so the native DLLs are Windows-only and stored in git-lfs. See `CLAUDE.md` for the checkout note; the nested `VL.ImGui/dependencies/ImGui.NET-nativebuild` submodule is left uninitialized.

## See Also

- [VL.StandardLibs Notes](../../notes/per-library/vvvv-ecosystem/vl-standardlibs/) — Study notes and reading plan
- [The Gray Book](../../references/the-gray-book/) — vvvv gamma documentation (submodule)
- [The Gray Book Notes](../../notes/per-reference/the-gray-book/) — Conceptual model of VL
