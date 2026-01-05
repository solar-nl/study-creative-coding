# nannou - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `Cargo.toml` (workspace) |
| **Package Manager** | Cargo / crates.io |
| **Build System** | Cargo |
| **Version** | 0.19.0 |

## Workspace Structure

nannou uses a Cargo workspace with multiple sub-crates:

```
nannou/
├── Cargo.toml          # Workspace root
├── nannou/             # Main crate
├── nannou_core/        # Core math and utilities
├── nannou_wgpu/        # wgpu wrapper
├── nannou_mesh/        # Mesh utilities
├── nannou_audio/       # Audio support
├── nannou_egui/        # egui integration
├── nannou_osc/         # OSC protocol
└── nannou_laser/       # Laser/ILDA support
```

## Dependencies by Category

### Graphics/Rendering

| Dependency | Version | Purpose |
|------------|---------|---------|
| `wgpu` | 0.17.1 | Cross-platform GPU abstraction |
| `lyon` | 0.17 | 2D path tessellation |
| `rusttype` | 0.8 | Font rendering with GPU cache |

### Windowing

| Dependency | Version | Purpose |
|------------|---------|---------|
| `winit` | 0.28 | Window creation and event handling |

### Math

| Dependency | Version | Purpose |
|------------|---------|---------|
| `glam` | (via wgpu) | Vector/matrix math |
| (nannou_core) | internal | Creative coding math utilities |

### Audio

| Dependency | Version | Purpose |
|------------|---------|---------|
| `cpal` | (via nannou_audio) | Cross-platform audio I/O |

### Image

| Dependency | Version | Purpose |
|------------|---------|---------|
| `image` | 0.23 | Image loading and processing |

### Serialization

| Dependency | Version | Purpose |
|------------|---------|---------|
| `serde` | (optional) | Serialization framework |

### Other Notable

| Dependency | Version | Purpose |
|------------|---------|---------|
| `rosc` | (via nannou_osc) | OSC protocol |
| `ilda` | (via nannou_laser) | Laser control format |
| `egui` | (via nannou_egui) | Immediate mode GUI |

## Dependency Graph Notes

- **wgpu is central** - All rendering flows through nannou_wgpu
- **Modular design** - Audio, OSC, laser are optional sub-crates
- **lyon for 2D** - All 2D path rendering uses lyon tessellation
- **Minimal dependencies** - Core is lightweight, features opt-in

## Key Files

- Main Cargo.toml: `frameworks/nannou/Cargo.toml`
- nannou crate: `frameworks/nannou/nannou/Cargo.toml`
- wgpu wrapper: `frameworks/nannou/nannou_wgpu/Cargo.toml`
