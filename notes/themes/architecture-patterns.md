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

### three.js
**Approach**: Class hierarchy, composition pattern
**Key insight**: Everything inherits from Object3D

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

## Comparison Matrix

| Framework | Module System | Extension Model | Config Approach |
|-----------|---------------|-----------------|-----------------|
| p5.js | Prototype | Library registration | Global state |
| Processing | Package | Contributed libraries | PApplet fields |
| three.js | ES Modules | External modules | Constructor options |
| OpenFrameworks | Namespace | Addons | Macros/defines |
| openrndr | Gradle | orx extensions | Builder pattern |
| nannou | Cargo | Crate features | Builder pattern |

## Recommendations for Rust Framework

1. **Workspace organization** — Separate crates for core, graphics, audio, etc.
2. **Builder pattern** — Fluent configuration
3. **Feature flags** — Optional functionality via Cargo features
4. **Extension traits** — Allow users to extend functionality
