# openrndr - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `build.gradle.kts` + `gradle/libs.versions.toml` |
| **Package Manager** | Gradle / Maven Central |
| **Build System** | Gradle (Kotlin DSL) |
| **Version** | 0.5.x |

## Module Structure

openrndr uses Kotlin Multiplatform with platform-specific modules:

```
openrndr/
├── build.gradle.kts
├── gradle/libs.versions.toml    # Version catalog
├── openrndr-application/        # Application framework
├── openrndr-draw/               # Drawing API
├── openrndr-math/               # Math utilities
├── openrndr-core/               # Core abstractions
├── openrndr-gl3/                # OpenGL 3.3+ (JVM)
├── openrndr-webgl/              # WebGL (JS)
└── openrndr-kartifact/          # Build utilities
```

## Dependencies by Category

### Graphics/Rendering

| Dependency | Version | Purpose | Platform |
|------------|---------|---------|----------|
| `lwjgl-opengl` | 3.3.6 | OpenGL bindings | JVM |
| `lwjgl-opengles` | 3.3.6 | OpenGL ES | JVM (mobile) |
| `lwjgl-egl` | 3.3.6 | EGL support | JVM |
| WebGL | native | Browser WebGL | JS |

### Windowing

| Dependency | Version | Purpose |
|------------|---------|---------|
| `lwjgl-glfw` | 3.3.6 | Window/input management |
| `lwjgl-nfd` | 3.3.6 | Native file dialogs |

### Audio

| Dependency | Version | Purpose |
|------------|---------|---------|
| `lwjgl-openal` | 3.3.6 | 3D positional audio |

### Video/Media

| Dependency | Version | Purpose |
|------------|---------|---------|
| `ffmpeg` (javacpp) | 7.1.1-1.5.12 | Video decode/encode |
| `javacpp` | 1.5.12 | Native code interop |

### Math

| Dependency | Version | Purpose |
|------------|---------|---------|
| Custom (openrndr-math) | internal | Kotlin-friendly math |
| LWJGL math | (via lwjgl) | Low-level math |

### Kotlin Ecosystem

| Dependency | Version | Purpose |
|------------|---------|---------|
| `kotlin-stdlib` | 2.2.21 | Standard library |
| `kotlinx-coroutines` | 1.10.2 | Async/concurrency |
| `kotlinx-serialization` | 1.9.0 | JSON/serialization |

### Testing

| Dependency | Version | Purpose |
|------------|---------|---------|
| `junit-jupiter` | 5.13.4 | Unit testing |
| `kotest` | 6.0.0 | Kotlin testing |

## Dependency Graph Notes

- **LWJGL is central** - All native functionality through LWJGL
- **Multiplatform** - JVM (desktop) and JS (web) targets
- **[FFmpeg](https://[ffmpeg](https://ffmpeg.org/).org/) for video** - Full codec support via javacpp
- **Coroutines-friendly** - Async design throughout
- **Modular** - Can use openrndr-math independently

## Version Catalog (libs.versions.toml)

openrndr uses Gradle's version catalog for dependency management:

```toml
[versions]
kotlin = "2.2.21"
lwjgl = "3.3.6"
kotlinx-coroutines = "1.10.2"
kotlinx-serialization = "1.9.0"
ffmpeg = "7.1.1-1.5.12"

[libraries]
lwjgl = { module = "org.lwjgl:lwjgl", version.ref = "lwjgl" }
lwjgl-opengl = { module = "org.lwjgl:lwjgl-opengl", version.ref = "lwjgl" }
# ... etc
```

## Key Files

- Version catalog: `frameworks/openrndr/gradle/libs.versions.toml`
- Root build: `frameworks/openrndr/build.gradle.kts`
- GL3 module: `frameworks/openrndr/openrndr-gl3/build.gradle.kts`
