# cinder - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | CMakeLists.txt |
| **Package Manager** | None (vendored) |
| **Build System** | CMake |
| **Version** | 0.9.4dev |

Cinder vendors dependencies and focuses on modern C++ practices.

## Project Structure

```
cinder/
├── CMakeLists.txt
├── include/
│   └── cinder/           # Public headers
├── src/
│   └── cinder/           # Implementation
├── blocks/               # Optional modules
└── lib/                  # Vendored dependencies
```

## Dependencies by Category

### Graphics/Rendering

| Dependency | Type | Purpose |
|------------|------|---------|
| OpenGL | System | Primary rendering API |
| ANGLE | Optional | OpenGL ES via DirectX |
| Metal | System (macOS) | Metal backend |

### Windowing

| Dependency | Type | Purpose |
|------------|------|---------|
| GLFW | Vendored | Cross-platform windows |
| Cocoa | System (macOS) | Native macOS windows |
| Win32 | System (Windows) | Native Windows |

### Image

| Dependency | Type | Purpose |
|------------|------|---------|
| stb_image | Vendored | Image loading |
| libpng | Vendored | PNG support |
| libjpeg | Vendored | JPEG support |

### Audio

| Dependency | Type | Purpose |
|------------|------|---------|
| Core Audio | System (macOS) | macOS audio |
| WASAPI | System (Windows) | Windows audio |
| RtAudio | Optional | Cross-platform |

### Video

| Dependency | Type | Purpose |
|------------|------|---------|
| AVFoundation | System (macOS) | Video on macOS |
| Media Foundation | System (Windows) | Video on Windows |
| QuickTime | Legacy | Older video support |

### Math

| Dependency | Type | Purpose |
|------------|------|---------|
| GLM | Vendored | Vector/matrix operations |

### Fonts

| Dependency | Type | Purpose |
|------------|------|---------|
| FreeType | Vendored | Font rendering |
| harfbuzz | Vendored | Text shaping |

### XML/JSON

| Dependency | Type | Purpose |
|------------|------|---------|
| RapidXML | Vendored | XML parsing |
| jsoncpp | Vendored | JSON parsing |

### Networking

| Dependency | Type | Purpose |
|------------|------|---------|
| Boost.Asio | Vendored | Async networking |
| cURL | Vendored | HTTP client |

## Block System (CinderBlocks)

Cinder extends via **blocks** (similar to oF addons):

| Block | Purpose |
|-------|---------|
| Cinder-ImGui | Dear ImGui integration |
| Cinder-OpenCV | OpenCV integration |
| Cinder-MIDI | MIDI support |
| Cinder-OSC | OSC protocol |
| Cinder-Syphon | Texture sharing (macOS) |
| Cinder-Spout | Texture sharing (Windows) |

## Platform Dependencies

### macOS
- Cocoa
- CoreFoundation
- AVFoundation
- CoreGraphics
- Metal (optional)

### Windows
- Win32
- COM
- Media Foundation
- Direct2D (optional)

### iOS
- UIKit
- Metal
- CoreMotion

## Dependency Philosophy

Cinder emphasizes:

1. **Modern C++** - C++17 features throughout
2. **Performance** - Optimized for real-time
3. **Vendored deps** - Controlled versions
4. **CMake-first** - Modern build system
5. **Blocks** - Modular extensions

## Build Configuration

CMake options control features:

```cmake
option(CINDER_DISABLE_AUDIO "Disable audio" OFF)
option(CINDER_DISABLE_VIDEO "Disable video" OFF)
option(CINDER_GL_ES "Use OpenGL ES" OFF)
option(CINDER_MSW_USE_ANGLE "Use ANGLE on Windows" OFF)
```

## Dependency Graph Notes

- **Boost.Asio for networking** - Unlike oF's Poco
- **GLM shared with oF** - Same math library choice
- **stb_image over FreeImage** - Simpler image loading
- **Block ecosystem** - Active community extensions

## Key Files

- CMake config: `frameworks/cinder/CMakeLists.txt`
- Include headers: `frameworks/cinder/include/cinder/`
