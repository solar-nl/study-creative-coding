# orx - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `build.gradle.kts` + `gradle/libs.versions.toml` |
| **Package Manager** | Gradle / Maven Central |
| **Build System** | Gradle (Kotlin DSL) |
| **Version** | 0.5.x |

orx (openrndr extensions) provides modular extensions for openrndr.

## Module Structure

```
orx/
├── build.gradle.kts
├── gradle/libs.versions.toml
├── orx-camera/              # Camera controls
├── orx-color/               # Color utilities
├── orx-compositor/          # Layer composition
├── orx-fx/                  # Post-processing effects
├── orx-gui/                 # GUI components
├── orx-image-fit/           # Image scaling
├── orx-kinect-v1/           # Kinect v1 sensor
├── orx-midi/                # MIDI support
├── orx-noise/               # Noise functions
├── orx-olive/               # Live coding
├── orx-panel/               # UI panels
├── orx-processing/          # Processing integration
├── orx-realsense2/          # Intel RealSense
├── orx-shapes/              # Shape utilities
├── orx-video-profiles/      # Video export
└── ... (50+ modules)
```

## Dependencies by Category

### Core Dependency

| Dependency | Version | Purpose |
|------------|---------|---------|
| `openrndr` | [0.5, 0.6.0) | Base framework |

### Vision/Sensors

| Dependency | Version | Purpose |
|------------|---------|---------|
| `boofcv` | 1.2.4 | Computer vision |
| `libfreenect` (javacpp) | 0.5.7-1.5.9 | Kinect v1 |
| `librealsense2` (javacpp) | 2.53.1-1.5.9 | Intel RealSense |

### Audio

| Dependency | Version | Purpose |
|------------|---------|---------|
| `minim` | 2.2.2 | Audio processing (Processing-style) |

### Networking

| Dependency | Version | Purpose |
|------------|---------|---------|
| `netty-all` | 4.2.7 | Network I/O |
| `ktor-server` | 3.3.3 | HTTP server |
| `rabbitcontrol-rcp` | 0.3.39 | Remote control protocol |

### Data Processing

| Dependency | Version | Purpose |
|------------|---------|---------|
| `gson` | 2.13.2 | JSON serialization |
| `antlr4` | 4.13.2 | Parser generation |
| `jsoup` | 1.21.2 | HTML parsing |

### Integration

| Dependency | Version | Purpose |
|------------|---------|---------|
| `processing-core` | 4.4.10 | Processing interop |

## Platform-Specific Modules

Some orx modules are JVM-only due to native dependencies:

| Module | Reason |
|--------|--------|
| `orx-kinect-v1` | Native Kinect driver |
| `orx-realsense2` | Native RealSense SDK |
| `orx-midi` | Native MIDI access |
| `orx-video-profiles` | [FFmpeg](https://[ffmpeg](https://ffmpeg.org/).org/) integration |
| `orx-processing` | Processing core (JVM) |

## Dependency Graph Notes

- **Modular by design** - Each orx module is independent
- **openrndr is the only required dependency** - Everything else optional
- **javacpp for native** - Sensors and video use javacpp bindings
- **Processing compatibility** - orx-processing enables Processing sketches

## Version Catalog (libs.versions.toml)

```toml
[versions]
openrndr = "[0.5, 0.6.0)"
boofcv = "1.2.4"
minim = "2.2.2"
ktor = "3.3.3"

[libraries]
openrndr-core = { module = "org.openrndr:openrndr-core", version.ref = "openrndr" }
boofcv-core = { module = "org.boofcv:boofcv-core", version.ref = "boofcv" }
# ... etc
```

## Key Files

- Version catalog: `frameworks/orx/gradle/libs.versions.toml`
- Root build: `frameworks/orx/build.gradle.kts`
