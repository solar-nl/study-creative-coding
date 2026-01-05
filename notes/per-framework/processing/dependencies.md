# processing - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `build.xml` (Ant) |
| **Package Manager** | None (vendored JARs) |
| **Build System** | Apache Ant |
| **Version** | 4.4.10 |

Processing uses Apache Ant for builds with vendored JAR files.

## Project Structure

```
processing/
├── build.xml
├── core/
│   ├── build.xml         # Core library build
│   └── src/              # Core source
├── java/                 # Processing IDE
├── lib/                  # Runtime libraries
│   └── [platform natives]
└── modes/                # Language modes
```

## Dependencies by Category

### Graphics/Rendering

| Dependency | Version | Purpose |
|------------|---------|---------|
| JOGL | varies | Java OpenGL bindings |
| gluegen-rt | varies | Native code generation |
| jogl-all.jar | platform-specific | OpenGL implementation |

### Platform Natives

JOGL requires platform-specific native libraries:

| Platform | Native Library |
|----------|----------------|
| macOS aarch64 | jogl-all-natives-macosx-aarch64.jar |
| macOS x86_64 | jogl-all-natives-macosx-universal.jar |
| Linux amd64 | jogl-all-natives-linux-amd64.jar |
| Linux aarch64 | jogl-all-natives-linux-aarch64.jar |
| Linux ARM | jogl-all-natives-linux-armv6hf.jar |
| Windows amd64 | jogl-all-natives-windows-amd64.jar |

### Math

| Dependency | Type | Purpose |
|------------|------|---------|
| PVector | Built-in | Custom vector class |
| PMatrix | Built-in | Matrix operations |

### Image

| Dependency | Type | Purpose |
|------------|------|---------|
| Java ImageIO | System | Image loading |
| Java AWT | System | Image manipulation |

### Audio

| Dependency | Type | Purpose |
|------------|------|---------|
| Minim | Library | Audio processing |
| Java Sound | System | Basic audio |

### Video

| Dependency | Type | Purpose |
|------------|------|---------|
| Processing Video | Library | GStreamer wrapper |

### Fonts

| Dependency | Type | Purpose |
|------------|------|---------|
| Java AWT | System | Font rendering |

### XML/JSON

| Dependency | Type | Purpose |
|------------|------|---------|
| Built-in | - | XML, JSON, Table classes |

## Library System

Processing extends via **contributed libraries**:

| Library | Purpose |
|---------|---------|
| Minim | Audio synthesis/analysis |
| Video | Video playback/capture |
| Sound | p5.js-compatible audio |
| Serial | Serial communication |
| Net | Networking |
| PDF | PDF export |
| SVG | SVG export |
| DXF | DXF export |

Libraries installed to `~/Documents/Processing/libraries/`.

## Modes

Processing supports multiple language modes:

| Mode | Language |
|------|----------|
| Java | Default Processing/Java |
| Python | Python mode |
| p5.js | JavaScript (web) |
| Android | Android apps |

## Build Process

Ant build produces:

```
build/
├── core.jar              # Core library
├── pde.jar               # IDE
└── processing-java       # CLI compiler
```

## Dependency Philosophy

Processing follows:

1. **JVM-based** - Java for cross-platform
2. **JOGL for OpenGL** - Standard Java graphics
3. **Vendored JARs** - No Maven/Gradle
4. **Library ecosystem** - Easy installation via IDE
5. **Educational focus** - Simplicity over flexibility

## Export Capabilities

Processing can export to:

| Target | Method |
|--------|--------|
| Application | Native executable with JRE |
| Applet | (deprecated) |
| Android | Via Android mode |
| Web | Via p5.js mode |

## Dependency Graph Notes

- **JOGL is critical** - All rendering through JOGL
- **Platform natives** - Must match OS/architecture
- **Ant is legacy** - Most Java projects use Gradle/Maven now
- **Library ecosystem** - Rich third-party libraries

## Key Files

- Core build: `frameworks/processing/core/build.xml`
- Natives: `frameworks/processing/core/library/`
