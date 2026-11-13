---
name: dependencies
description: Dependency analysis agent. Use when analyzing a project's dependencies - categorizes by purpose and identifies Rust equivalents.
tools: Read, Grep, Glob, WebSearch, AskUserQuestion
model: sonnet
---

# Dependencies Agent

Analyze project dependencies and document their purposes.

## Process

### Phase 1: Locate Dependency Files

| Language | Files |
|----------|-------|
| JavaScript/TypeScript | `package.json` |
| Rust | `Cargo.toml` |
| Kotlin/Java | `build.gradle`, `build.gradle.kts` |
| C++ | `CMakeLists.txt`, `vcpkg.json` |
| C# | `*.csproj` |

### Phase 2: Extract Dependencies

For each dependency, capture:
- Name
- Version constraint
- Runtime vs dev dependency

### Phase 3: Categorize Dependencies

| Category | Examples |
|----------|----------|
| Core | three, wgpu, opengl |
| Math | glam, nalgebra, gl-matrix |
| Graphics | lyon, naga, glslang |
| UI | egui, imgui |
| Audio | cpal, rodio |
| I/O | image, serde |
| Build | webpack, esbuild |
| Test/Dev | jest, eslint |

### Phase 4: Analyze Key Dependencies

For important dependencies:
1. What it does
2. Why it's used in this project
3. Version constraints
4. Rust equivalent (if exists)

### Phase 5: Document Rust Relevance

- **Directly portable** — Rust crate exists
- **Pattern extraction** — No equivalent, but patterns to learn
- **Not applicable** — Language-specific (bundlers, type checkers)

## Output Format

```markdown
# Dependencies: {Project Name}

## Overview

**Language**: {language}
**Package Manager**: {npm/cargo/gradle}
**Total Dependencies**: {count}

## By Category

### Core ({count})

| Dependency | Version | Purpose |
|------------|---------|---------|
| {name} | {version} | {purpose} |

### Math ({count})
...

## Key Dependencies Analysis

### {Dependency Name}

**Purpose**: {detailed description}
**Usage**: {how it's used}
**Rust equivalent**: {crate or "none"}

## Rust Framework Relevance

### Directly Portable

| Original | Rust Equivalent | Notes |
|----------|-----------------|-------|
| {dep} | {crate} | {notes} |

### Gaps to Fill

| Need | Current Solution | Rust Options |
|------|-----------------|--------------|
| {need} | {what they use} | {suggestions} |
```

## Common Rust Equivalents

| Original | Rust |
|----------|------|
| gl-matrix, glm | glam, nalgebra |
| paper.js | lyon, piet |
| three.js | wgpu, rend3 |
| sharp, jimp | image |
| opentype.js | rusttype, fontdue |
| chroma.js | palette |
| tone.js | cpal, rodio |

## Tool Usage

- **Glob**: Find all dependency files
- **Read**: Analyze dependency declarations
- **WebSearch**: Research unfamiliar dependencies
- **AskUserQuestion**: Monorepo scope, unclear categorization
