# Insights: Patterns for Your Rust Framework

This directory contains extracted patterns and recommendations from studying creative coding frameworks.

## Purpose

As you study each framework, document actionable insights here. These will inform the design of your Rust creative coding framework targeting desktop, mobile, and web.

## Documents

- **[API Recommendations](./api-recommendations.md)** — Best practices for user-facing APIs
- **[Architecture Decisions](./architecture-decisions.md)** — ADRs for your framework
- **[Rust-Specific Patterns](./rust-specific.md)** — Rust idioms that map to patterns found
- **[ImGui Editor Patterns](./imgui-editor-patterns.md)** — Patterns to adopt, adapt and avoid for a Dear ImGui editor in Rust, distilled from tixl's editor; encoding conventions in types instead of prose
- **[Node Instance Identity](./node-instance-identity.md)** — Name-derived vs random IDs across tixl, cables, werkkzeug4, apEx; what a rename transaction must rewrite
- **[Open Formats](./open-formats.md)** — Tiering of open asset formats for Flux (import tier 1 and 2, export, ignore) with crates; the OpenUSD stance (interchange, flatten on import and export, keep the operator graph as source of truth); OpenPBR as the material vocabulary; recorded as ADR-006
- **[2D Rendering Strategy](./2d-rendering-strategy.md)** — How Flux turns paths and text into pixels on wgpu: sparse-strip coverage via `vello_gpu` behind a `PathRasterizer` trait, instanced analytic primitives, Lyon only for meshes; scored against five strategies

## Extraction Process

When studying a framework:

1. Identify patterns that work well
2. Identify anti-patterns to avoid
3. Consider how it maps to Rust
4. Document in the appropriate file

## Key Questions to Answer

### API Design
- What makes an API "feel right" for creative coding?
- How much typing should users do for common operations?
- How to balance simplicity with power?

### Architecture
- How to structure for cross-platform (desktop, mobile, web)?
- How to separate core from optional features?
- How to support extensions/plugins?

### Rust-Specific
- How to leverage Rust's type system?
- How to make ownership ergonomic for creative coding?
- How to handle async (loading, events)?
