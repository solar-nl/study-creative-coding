# Theme: Architecture Patterns

> Cross-cutting analysis of how different frameworks are architecturally structured.

## Concept Overview

Architecture patterns determine how a framework's code is organized:
- Module structure and dependencies
- Plugin/extension systems
- Configuration approaches
- Core vs optional functionality

## Framework Implementations

### p5.js
**Approach**: Prototype-based, single global constructor
**Key insight**: Methods attached to `p5.prototype`

### Processing
**Approach**: Class-based, PApplet as base class
**Key insight**: User extends PApplet

### OpenFrameworks
**Approach**: Namespace-based, ofApp inheritance
**Key insight**: Addon system for extensions

### Cinder
**Approach**: Modern C++, templates and RAII
**Key insight**: Blocks for extensions

### openrndr
**Approach**: Kotlin DSL, builder pattern
**Key insight**: Extension functions for DSL

### nannou
**Approach**: Rust workspace, builder pattern
**Key insight**: Separate crates for different concerns

## Library Architectures

### three.js
**Approach**: Class hierarchy, composition pattern
**Key insight**: Everything inherits from Object3D; scene graph based

### toxiclibs
**Approach**: Package-based, immutable geometry
**Key insight**: Color theory via strategy pattern; geometry via vectors

### orx
**Approach**: Gradle modules, openrndr extensions
**Key insight**: Each extension is a separate Gradle module

## Comparison Matrix

### Frameworks

| Framework | Module System | Extension Model | Config Approach |
|-----------|---------------|-----------------|-----------------|
| p5.js | Prototype | Library registration | Global state |
| Processing | Package | Contributed libraries | PApplet fields |
| OpenFrameworks | Namespace | Addons | Macros/defines |
| openrndr | Gradle | orx extensions | Builder pattern |
| nannou | Cargo | Crate features | Builder pattern |

### Libraries

| Library | Module System | Integration Model | Config Approach |
|---------|---------------|-------------------|-----------------|
| three.js | ES Modules | External modules | Constructor options |
| toxiclibs | Maven/Gradle | Import packages | Factory methods |
| orx | Gradle | Depend on modules | DSL extensions |
| wgpu | Cargo | Depend on crate | Builder pattern |

## Recommendations for Rust Framework

1. **Workspace organization** — Separate crates for core, graphics, audio, etc.
2. **Builder pattern** — Fluent configuration
3. **Feature flags** — Optional functionality via Cargo features
4. **Extension traits** — Allow users to extend functionality
