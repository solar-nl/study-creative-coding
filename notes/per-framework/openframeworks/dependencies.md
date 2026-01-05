# openframeworks - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | CMakeLists.txt + source includes |
| **Package Manager** | None (vendored) |
| **Build System** | CMake / Make / IDE projects |
| **Version** | 0.12.x |

openframeworks vendors most dependencies directly in the repository.

## Project Structure

```
openframeworks/
├── libs/
│   ├── openFrameworks/     # Core framework
│   │   ├── 3d/
│   │   ├── app/
│   │   ├── communication/
│   │   ├── events/
│   │   ├── gl/
│   │   ├── graphics/
│   │   ├── math/
│   │   ├── sound/
│   │   ├── types/
│   │   ├── utils/
│   │   └── video/
│   └── [vendored libs]/    # Third-party libraries
├── addons/                 # Official addons
└── examples/               # Example projects
```

## Dependencies by Category

### Graphics/Rendering

| Dependency | Type | Purpose |
|------------|------|---------|
| OpenGL | System | Primary rendering API |
| GLEW | Vendored | OpenGL extension loading |
| GLM | Vendored | Math library |

### Windowing

| Dependency | Type | Purpose |
|------------|------|---------|
| GLFW | Vendored | Window/input management |
| Platform native | System | macOS: Cocoa, Windows: Win32 |

### Image

| Dependency | Type | Purpose |
|------------|------|---------|
| FreeImage | Vendored | Image loading/saving |
| libjpeg | Vendored | JPEG support |
| libpng | Vendored | PNG support |
| libtiff | Vendored | TIFF support |

### Audio

| Dependency | Type | Purpose |
|------------|------|---------|
| RtAudio | Vendored | Cross-platform audio |
| OpenAL | System/Vendored | 3D audio |
| FMOD | Optional addon | Professional audio |

### Video

| Dependency | Type | Purpose |
|------------|------|---------|
| GStreamer | System (Linux) | Video playback |
| AVFoundation | System (macOS) | Video capture/playback |
| DirectShow | System (Windows) | Video on Windows |

### Networking

| Dependency | Type | Purpose |
|------------|------|---------|
| Poco | Vendored | HTTP, networking utilities |

### Math

| Dependency | Type | Purpose |
|------------|------|---------|
| GLM | Vendored | Vector/matrix math |

### Fonts

| Dependency | Type | Purpose |
|------------|------|---------|
| FreeType | Vendored | Font rendering |

### XML/JSON

| Dependency | Type | Purpose |
|------------|------|---------|
| pugixml | Vendored | XML parsing |

## Addon System

openframeworks extends via **addons**:

| Addon | Purpose |
|-------|---------|
| ofxGui | Built-in GUI |
| ofxOsc | OSC protocol |
| ofxNetwork | TCP/UDP networking |
| ofxSvg | SVG loading |
| ofxXmlSettings | XML settings |
| ofxAssimpModelLoader | 3D model loading |
| ofxKinect | Kinect v1 support |

Community addons available at [ofxaddons.com](http://ofxaddons.com).

## Platform Dependencies

### macOS
- Cocoa framework
- CoreFoundation
- CoreServices
- AVFoundation
- Metal (optional)

### Windows
- Win32 API
- DirectShow
- WASAPI (audio)

### Linux
- X11 / Wayland
- GStreamer
- PulseAudio / ALSA

## Dependency Philosophy

openframeworks follows **vendored dependencies**:

1. **Self-contained** - All deps in repository
2. **No package manager** - Avoids version conflicts
3. **Platform projects** - IDE-specific build files
4. **Addon modularity** - Optional features via addons

## Build Approaches

| Platform | Build System |
|----------|--------------|
| macOS | Xcode project |
| Windows | Visual Studio |
| Linux | CMake / Make |
| All | CMake (unified) |

## Dependency Graph Notes

- **Heavy vendoring** - Most deps compiled from source
- **Platform-specific video** - Different backends per OS
- **GLM for math** - Industry standard C++ math
- **Addon ecosystem** - Extends without bloating core

## Key Files

- Core: `frameworks/openframeworks/libs/openFrameworks/`
- Addons: `frameworks/openframeworks/addons/`
