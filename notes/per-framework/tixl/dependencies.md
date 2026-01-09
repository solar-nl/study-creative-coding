# tixl - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `.csproj` (MSBuild) |
| **Package Manager** | NuGet |
| **Build System** | MSBuild / .NET SDK |
| **Version** | 4.1.0.8 (alpha) |
| **Target Framework** | .NET 9.0 |

## Project Structure

```
tixl/
├── t3.sln                    # Solution file
├── Tixl.props                # Shared properties
├── Core/Core.csproj          # Core framework
├── Editor/Editor.csproj      # Main application
├── Operators/
│   ├── Lib/Lib.csproj        # Built-in operators
│   ├── Ndi/ndi.csproj        # NDI video
│   ├── Spout/spout.csproj    # Texture sharing
│   └── ...
├── ImguiWindows/             # Dear ImGui components
├── SilkWindows/              # Silk.NET windowing
├── Player/                   # Standalone player
└── Serialization/            # Save/load
```

## Dependencies by Category

### Graphics/Rendering

| Dependency | Version | Purpose |
|------------|---------|---------|
| `SharpDX.Direct3D11` | 4.2.0 | DirectX 11 rendering |
| `SharpDX.Direct2D1` | 4.2.0 | 2D rendering |
| `SharpDX.D3DCompiler` | 4.2.0 | HLSL shader compilation |
| `SharpDX.Mathematics` | 4.2.0 | Math library |
| `SharpDX.MediaFoundation` | 4.2.0 | Video decode/encode |
| `SharpDX.XInput` | 4.2.0 | Gamepad input |

### UI Framework

| Dependency | Version | Purpose |
|------------|---------|---------|
| `ImGui.NET` | 1.89.9.3 | Dear ImGui bindings |
| `Silk.NET.Windowing` | 2.22.0 | Cross-platform windowing |
| `Silk.NET.Input` | 2.22.0 | Input handling |

### 3D Formats

| Dependency | Version | Purpose |
|------------|---------|---------|
| `SharpGLTF.Core` | 1.0.4 | glTF 2.0 model loading |
| `JeremyAnsel.Media.Dds` | 2.0.4 | DDS texture format |

### Audio

| Dependency | Version | Purpose |
|------------|---------|---------|
| `ManagedBass` | 3.1.1 | Audio playback |
| `ManagedBass.Wasapi` | 3.1.1 | Windows audio capture |
| `NAudio.Midi` | 2.2.1 | MIDI support |

### Vision/Image

| Dependency | Version | Purpose |
|------------|---------|---------|
| `OpenCvSharp4` | 4.11.0 | Computer vision |
| `OpenCvSharp4.Extensions` | 4.11.0 | Image extensions |
| `OpenCvSharp4.Windows` | 4.11.0 | Windows runtime |

### Networking

| Dependency | Version | Purpose |
|------------|---------|---------|
| `Rug.Osc` | 1.2.5 | OSC protocol |
| NDI SDK | native | Video over IP |

### Serialization

| Dependency | Version | Purpose |
|------------|---------|---------|
| `Newtonsoft.Json` | 13.0.3 | JSON serialization |

### Code Analysis (Editor)

| Dependency | Version | Purpose |
|------------|---------|---------|
| `Microsoft.CodeAnalysis.CSharp` | 4.9.0 | Roslyn compiler |
| `Microsoft.CodeAnalysis.Workspaces` | 4.9.0 | Code workspace |
| `Sentry` | 4.1.1 | Error reporting |

### System

| Dependency | Version | Purpose |
|------------|---------|---------|
| `System.IO.Ports` | (SDK) | Serial communication |
| `System.Management` | 8.0.0 | Windows system info |

## Dependency Graph Notes

- **SharpDX is central** - All rendering through DirectX 11 wrapper
- **ImGui for UI** - Immediate mode GUI, not WinForms
- **Silk.NET for windowing** - Cross-platform (Win/Linux/macOS)
- **OpenCV for vision** - Heavy image processing capabilities
- **Roslyn integration** - Live code editing/compilation in editor

## Platform Considerations

While targeting cross-platform via Silk.NET, some dependencies are Windows-specific:
- SharpDX (DirectX) - Windows only
- ManagedBass.Wasapi - Windows audio API
- OpenCvSharp4.Windows - Windows runtime

For true cross-platform, would need:
- Graphics: Replace SharpDX with Veldrid or Silk.NET.OpenGL
- Audio: Cross-platform audio library

## Key Files

- Core dependencies: `visual-programming/tixl/Core/Core.csproj`
- Editor dependencies: `visual-programming/tixl/Editor/Editor.csproj`
- ImGui integration: `visual-programming/tixl/ImguiWindows/ImguiWindows.csproj`
