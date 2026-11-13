# Rust Libraries

Native Rust libraries for graphics and creative coding.

## Libraries

| Library | Description |
|---------|-------------|
| [wgpu](./wgpu/) | Safe, portable WebGPU implementation |
| [vello](./vello/) | GPU-accelerated 2D vector renderer from Linebender |

## About wgpu

wgpu is a cross-platform graphics API that implements the WebGPU standard in Rust. It provides backends for:

- Vulkan (Linux, Windows, Android)
- Metal (macOS, iOS)
- DX12 (Windows)
- WebGPU (browsers via wasm)

## About vello

vello is a 2D vector renderer (paths, gradients, images, clips, text) that targets the same place in the stack as Skia or Cairo. The workspace holds three renderers: `vello_cpu` and `vello_gpu`, which share a CPU-side Sparse Strips pipeline and differ in where rasterization happens, and the original compute-shader renderer `vello`, kept under `research/`. `vello_gpu` runs on wgpu and WebGL2 without compute shaders.

Note: the upstream repository stores test snapshot PNGs in git-lfs. See `CLAUDE.md` for the checkout note.

## See Also

- [nannou Framework](../../frameworks/nannou/) — Creative coding framework built on wgpu
- [nannou Notes](../../notes/per-framework/nannou/) — Framework documentation
- [vello Notes](../../notes/per-library/rust/vello/) — Study notes and reading plan
